//
//  MTOpenCC.mm
//  MacTagger — OpenCC 简繁转换桥接层（实现）
//
//  设计要点：
//  1. **两个方向各开一个 `opencc_t`，进程内长驻**。`opencc_open` 要读几 MB 词典并建索引，
//     每次转换都开一次的话，批量转 3000 个标签就是 3000 次全量装载 —— 慢到不可用。
//  2. **配置文件传绝对路径**。OpenCC 解析 `t2s.json` 里的词典引用时以配置文件所在目录为基准，
//     只传文件名的话得靠它自己的内建搜索路径（Homebrew 的 bottle 没有那条路径），必然失败。
//     反过来说，只要 `.ocd2` 与 `.json` 平铺在同一个目录里，传绝对路径就能装载 ——
//     不用 chdir，也不受进程当前目录影响（已实测：从 `/` 跑仍然成功）。
//  3. **锁**。`opencc_convert_utf8` 内部会写转换器的分词缓存，多线程直接并发调用会踩坏它。
//     批量匹配是多源并发的，所以这里必须串行化；单次转换是微秒级，锁的代价可以忽略。
//  4. **绝不抛异常、绝不返回 nil**。装不上就把 `isAvailable` 置 NO、`convert:` 原样吐回入参。
//

#import "MTOpenCC.h"

#import <opencc/opencc.h>

#import <mutex>
#import <string>
#import <vector>

#pragma mark - 进程内单例状态

namespace {

struct MTOpenCCState {
    std::mutex mutex;
    bool loaded = false;
    opencc_t toSimplified = nullptr;    // t2s.json
    opencc_t toTraditional = nullptr;   // s2t.json
    NSString *configDirectory = nil;
    NSString *unavailableReason = nil;
};

MTOpenCCState &state() {
    static MTOpenCCState s;
    return s;
}

/// 读一个环境变量，非空时按 UTF-8 转成 NSString；否则返回 nil。
/// 环境变量里塞了非法 UTF-8 时 `stringWithUTF8String:` 会返回 nil，
/// 直接 addObject 会崩 —— 所以这里统一过一道。
NSString *_Nullable MTOpenCCEnvPath(const char *name) {
    const char *raw = getenv(name);
    if (raw == nullptr || *raw == '\0') { return nil; }
    return [NSString stringWithUTF8String:raw];
}

/// 候选配置目录，按优先级。
///
/// 顺序（改动理由见 `Scripts/embed-dylibs.sh`）：
///   ① **App 包内自带的一份**（`Contents/Resources/opencc`）。构建阶段从 Homebrew 拷进来，
///      成品 App 的唯一来源 —— 装了 Homebrew 的机器上也走这条，免得「本机能跑、
///      别人机器起不来」这种只在别人电脑上复现的 bug。
///      `mactagger-probe` 不是 bundle，`resourcePath` 指向可执行文件所在目录，
///      那底下没有 `opencc/`，这一条自然落空，于是 CLI 照旧走 ③。
///   ② `MACTAGGER_OPENCC_DIR` —— 显式指定，给 probe / 自动化测试用
///      （拿它把 App 包里那份数据喂给 CLI 验证）。
///   ③ `OPENCC_DATA` —— 兼容老用法，保留。
///   ④ Homebrew / MacPorts / 系统级安装，兜底。
NSArray<NSString *> *MTOpenCCSearchDirs(void) {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];

    NSString *resources = [[NSBundle mainBundle] resourcePath];
    if (resources.length > 0) {
        [dirs addObject:[resources stringByAppendingPathComponent:@"opencc"]];
    }

    NSString *explicitDir = MTOpenCCEnvPath("MACTAGGER_OPENCC_DIR");
    if (explicitDir.length > 0) { [dirs addObject:explicitDir]; }

    NSString *openccData = MTOpenCCEnvPath("OPENCC_DATA");
    if (openccData.length > 0) { [dirs addObject:openccData]; }

    [dirs addObjectsFromArray:@[ @"/opt/homebrew/share/opencc",
                                @"/usr/local/share/opencc",
                                @"/usr/share/opencc",
                                @"/opt/local/share/opencc" ]];
    return dirs;
}

/// 找到同时含 `t2s.json` 与 `s2t.json` 的那个目录。
NSString *_Nullable MTOpenCCResolveConfigDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in MTOpenCCSearchDirs()) {
        NSString *t2s = [dir stringByAppendingPathComponent:@"t2s.json"];
        NSString *s2t = [dir stringByAppendingPathComponent:@"s2t.json"];
        if ([fm fileExistsAtPath:t2s] && [fm fileExistsAtPath:s2t]) {
            return dir;
        }
    }
    return nil;
}

/// `opencc_open` 失败时返回 `(opencc_t)-1`，不是 NULL —— 这一处踩错就会拿一个野指针去转换。
bool MTOpenCCHandleValid(opencc_t h) {
    return h != nullptr && h != reinterpret_cast<opencc_t>(-1);
}

/// 装载两个方向的转换器。调用方必须已持锁。
void MTOpenCCLoadLocked(void) {
    MTOpenCCState &s = state();
    if (s.loaded) { return; }
    s.loaded = true;

    NSString *dir = MTOpenCCResolveConfigDir();
    if (dir == nil) {
        // App 包里本该自带一份（构建阶段拷的）；走到这里说明包被拆过或构建脚本没跑，
        // 所以提示同时给「重新构建」和「装 Homebrew」两条路。
        s.unavailableReason =
            [NSString stringWithFormat:@"找不到 OpenCC 配置目录（已试：%@）。"
                                       @"App 包内应自带 Contents/Resources/opencc；"
                                       @"若在命令行下运行，请 brew install opencc "
                                       @"或用 MACTAGGER_OPENCC_DIR 指定目录。",
                                       [MTOpenCCSearchDirs() componentsJoinedByString:@"、"]];
        return;
    }
    s.configDirectory = [dir copy];

    try {
        NSString *t2s = [dir stringByAppendingPathComponent:@"t2s.json"];
        NSString *s2t = [dir stringByAppendingPathComponent:@"s2t.json"];
        opencc_t a = opencc_open(t2s.fileSystemRepresentation);
        opencc_t b = opencc_open(s2t.fileSystemRepresentation);
        if (!MTOpenCCHandleValid(a) || !MTOpenCCHandleValid(b)) {
            const char *why = opencc_error();
            s.unavailableReason =
                [NSString stringWithFormat:@"opencc_open 失败：%s",
                                           (why && *why) ? why : "未知原因"];
            if (MTOpenCCHandleValid(a)) { opencc_close(a); }
            if (MTOpenCCHandleValid(b)) { opencc_close(b); }
            return;
        }
        s.toSimplified = a;
        s.toTraditional = b;
        s.unavailableReason = nil;
    } catch (const std::exception &e) {
        s.unavailableReason = [NSString stringWithFormat:@"OpenCC 原生层异常：%s", e.what()];
    } catch (...) {
        s.unavailableReason = @"OpenCC 原生层抛出了未知异常";
    }
}

}  // namespace

#pragma mark -

@implementation MTOpenCC

+ (BOOL)isAvailable {
    MTOpenCCState &s = state();
    std::lock_guard<std::mutex> guard(s.mutex);
    MTOpenCCLoadLocked();
    return MTOpenCCHandleValid(s.toSimplified) && MTOpenCCHandleValid(s.toTraditional);
}

+ (NSString *)configDirectory {
    MTOpenCCState &s = state();
    std::lock_guard<std::mutex> guard(s.mutex);
    MTOpenCCLoadLocked();
    return s.configDirectory;
}

+ (NSString *)unavailableReason {
    MTOpenCCState &s = state();
    std::lock_guard<std::mutex> guard(s.mutex);
    MTOpenCCLoadLocked();
    return s.unavailableReason;
}

+ (NSArray<NSString *> *)searchedDirectories {
    return MTOpenCCSearchDirs();
}

+ (NSString *)convert:(NSString *)text direction:(MTChineseDirection)direction {
    if (text == nil || text.length == 0) { return text ?: @""; }

    MTOpenCCState &s = state();
    std::lock_guard<std::mutex> guard(s.mutex);
    MTOpenCCLoadLocked();

    opencc_t handle = (direction == MTChineseDirectionToSimplified) ? s.toSimplified
                                                                    : s.toTraditional;
    if (!MTOpenCCHandleValid(handle)) { return text; }

    const char *input = text.UTF8String;
    if (input == nullptr) { return text; }

    char *converted = nullptr;
    try {
        converted = opencc_convert_utf8(handle, input, (size_t)-1);
    } catch (...) {
        converted = nullptr;
    }
    if (converted == nullptr) { return text; }

    NSString *out = [NSString stringWithUTF8String:converted];
    opencc_convert_utf8_free(converted);
    return out ?: text;
}

+ (void)reload {
    MTOpenCCState &s = state();
    std::lock_guard<std::mutex> guard(s.mutex);
    if (MTOpenCCHandleValid(s.toSimplified)) { opencc_close(s.toSimplified); }
    if (MTOpenCCHandleValid(s.toTraditional)) { opencc_close(s.toTraditional); }
    s.toSimplified = nullptr;
    s.toTraditional = nullptr;
    s.configDirectory = nil;
    s.unavailableReason = nil;
    s.loaded = false;
    MTOpenCCLoadLocked();
}

@end
