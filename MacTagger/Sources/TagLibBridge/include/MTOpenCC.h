//
//  MTOpenCC.h
//  MacTagger — OpenCC 简繁转换桥接层（公开接口）
//
//  与 `MTTagLibBridge.h` 同样的三条约定：
//    * 纯 Objective-C 头文件，不含任何 C++ 声明，可安全进 Swift bridging header；
//    * 所有入口都用 C++ try/catch(...) 兜底，**绝不把异常传播到 Swift**；
//    * 任何失败都**返回原文**而不是空串 —— 简繁转换是"锦上添花"的一步，
//      引擎装不上时用户看到繁体总好过看到空白标题。
//
//  依赖：
//    * **编译期**：Homebrew opencc（brew install opencc），头文件与库在 /opt/homebrew 下；
//    * **运行期**：App 不依赖 Homebrew。libopencc（连同 libmarisa）在构建阶段被
//      `Scripts/embed-dylibs.sh` 拷进 `Contents/Frameworks`，转换配置
//      （t2s.json / s2t.json + .ocd2 词典）拷进 `Contents/Resources/opencc`。
//
//  配置目录解析顺序（实现见 MTOpenCC.mm 的 `MTOpenCCSearchDirs`）：
//      ① `Contents/Resources/opencc`（App 包内自带）
//      ② 环境变量 `MACTAGGER_OPENCC_DIR`（probe / 自动化测试用）
//      ③ 环境变量 `OPENCC_DATA`（兼容老用法）
//      ④ /opt/homebrew/share/opencc 等系统级安装（兜底，CLI 走这条）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// OpenCC 转换方向。
typedef NS_ENUM(NSInteger, MTChineseDirection) {
    /// 繁体 → 简体（t2s.json）
    MTChineseDirectionToSimplified  = 0,
    /// 简体 → 繁体（s2t.json）
    MTChineseDirectionToTraditional = 1,
};

@interface MTOpenCC : NSObject

#pragma mark - 环境

/// 两个方向的转换器是否都成功装载。为 NO 时 `convert:` 原样返回入参。
@property (class, nonatomic, readonly) BOOL isAvailable;

/// 实际解析到的配置目录（App 里通常是 `…/MacTagger.app/Contents/Resources/opencc`，
/// CLI 里通常是 `/opt/homebrew/share/opencc`）。没找到时为 nil。
@property (class, nonatomic, readonly, nullable) NSString *configDirectory;

/// 不可用时的原因（找不到配置目录 / opencc_open 失败 / 原生异常）。可用时为 nil。
@property (class, nonatomic, readonly, nullable) NSString *unavailableReason;

/// 依次尝试的配置目录，按优先级。诊断用。
@property (class, nonatomic, readonly) NSArray<NSString *> *searchedDirectories;

#pragma mark - 转换

/// 转换一段 UTF-8 文本。
/// @param text      待转换文本。nil / 空串原样返回。
/// @param direction 方向。
/// @return 转换后的文本；引擎不可用或原生层出错时**返回入参原文**，绝不返回 nil。
+ (NSString *)convert:(NSString *)text direction:(MTChineseDirection)direction;

/// 强制重新装载（改了 `MACTAGGER_OPENCC_DIR` / Homebrew 前缀之类的场景）。测试与诊断用。
+ (void)reload;

@end

NS_ASSUME_NONNULL_END
