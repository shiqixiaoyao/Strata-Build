//
//  SideStoreTranslator.m
//  SideStore 运行时汉化：注入 SideStore dylib，替换界面上的英文文案。
//
//  两条路径各管一半：
//  1. 打包时把词条并进 LiveContainer 的 Localizable（SwiftUI 的 LocalizedStringKey
//     与 NSLocalizedString 都查 main bundle），覆盖绝大多数页面。
//  2. 这个 dylib 兜住代码里直接赋值的 UIKit 文案（弹窗标题、按钮标题、输入框占位符），
//     这些不走本地化表。
//
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SideStoreStrings.h"

static NSString *SSTTranslate(NSString *input) {
    if (input.length == 0) return input;
    NSString *hit = SSTLookupExact(input);
    if (hit) return hit;
    return SSTLookupPattern(input);
}

#pragma mark - swizzle helpers

static void SSTSwizzleInstance(Class cls, SEL original, SEL replacement) {
    Method m1 = class_getInstanceMethod(cls, original);
    Method m2 = class_getInstanceMethod(cls, replacement);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1, m2);
}

static void SSTSwizzleClass(Class cls, SEL original, SEL replacement) {
    Method m1 = class_getClassMethod(cls, original);
    Method m2 = class_getClassMethod(cls, replacement);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1, m2);
}

#pragma mark - UILabel

@implementation UILabel (SSTTranslator)

- (void)sst_setText:(NSString *)text {
    [self sst_setText:SSTTranslate(text)];
}

- (void)sst_setAttributedText:(NSAttributedString *)text {
    if (!text.length) { [self sst_setAttributedText:text]; return; }
    NSString *zh = SSTTranslate(text.string);
    if (zh == text.string || [zh isEqualToString:text.string]) {
        [self sst_setAttributedText:text];
        return;
    }
    NSMutableAttributedString *copy = [text mutableCopy];
    [copy replaceCharactersInRange:NSMakeRange(0, copy.length) withString:zh];
    [self sst_setAttributedText:copy];
}

@end

#pragma mark - UIButton

@implementation UIButton (SSTTranslator)

- (void)sst_setTitle:(NSString *)title forState:(UIControlState)state {
    [self sst_setTitle:SSTTranslate(title) forState:state];
}

@end

#pragma mark - UINavigationItem / UITabBarItem / UIBarButtonItem

@implementation UINavigationItem (SSTTranslator)

- (void)sst_setTitle:(NSString *)title {
    [self sst_setTitle:SSTTranslate(title)];
}

@end

@implementation UITabBarItem (SSTTranslator)

- (void)sst_setTitle:(NSString *)title {
    [self sst_setTitle:SSTTranslate(title)];
}

@end

@implementation UIBarButtonItem (SSTTranslator)

- (void)sst_setTitle:(NSString *)title {
    [self sst_setTitle:SSTTranslate(title)];
}

@end

#pragma mark - UITextField / UISearchBar

@implementation UITextField (SSTTranslator)

- (void)sst_setPlaceholder:(NSString *)placeholder {
    [self sst_setPlaceholder:SSTTranslate(placeholder)];
}

@end

@implementation UISearchBar (SSTTranslator)

- (void)sst_setPlaceholder:(NSString *)placeholder {
    [self sst_setPlaceholder:SSTTranslate(placeholder)];
}

@end

#pragma mark - UIViewController

@implementation UIViewController (SSTTranslator)

- (void)sst_setTitle:(NSString *)title {
    [self sst_setTitle:SSTTranslate(title)];
}

@end

#pragma mark - UIAlertController / UIAlertAction

@implementation UIAlertController (SSTTranslator)

+ (instancetype)sst_alertControllerWithTitle:(NSString *)title
                                     message:(NSString *)message
                              preferredStyle:(UIAlertControllerStyle)style {
    return [self sst_alertControllerWithTitle:SSTTranslate(title)
                                      message:SSTTranslate(message)
                               preferredStyle:style];
}

@end

@implementation UIAlertAction (SSTTranslator)

+ (instancetype)sst_actionWithTitle:(NSString *)title
                              style:(UIAlertActionStyle)style
                            handler:(void (^)(UIAlertAction *))handler {
    return [self sst_actionWithTitle:SSTTranslate(title) style:style handler:handler];
}

@end

#pragma mark - entry

__attribute__((constructor))
static void SSTInstall(void) {
    // 只在被注入的进程里生效；dylib 本身就只挂在 SideStore 上。
    SSTBuildTables();

    SSTSwizzleInstance([UILabel class], @selector(setText:), @selector(sst_setText:));
    SSTSwizzleInstance([UILabel class], @selector(setAttributedText:), @selector(sst_setAttributedText:));
    SSTSwizzleInstance([UIButton class], @selector(setTitle:forState:), @selector(sst_setTitle:forState:));
    SSTSwizzleInstance([UINavigationItem class], @selector(setTitle:), @selector(sst_setTitle:));
    SSTSwizzleInstance([UITabBarItem class], @selector(setTitle:), @selector(sst_setTitle:));
    SSTSwizzleInstance([UIBarButtonItem class], @selector(setTitle:), @selector(sst_setTitle:));
    SSTSwizzleInstance([UITextField class], @selector(setPlaceholder:), @selector(sst_setPlaceholder:));
    SSTSwizzleInstance([UISearchBar class], @selector(setPlaceholder:), @selector(sst_setPlaceholder:));
    SSTSwizzleInstance([UIViewController class], @selector(setTitle:), @selector(sst_setTitle:));
    SSTSwizzleClass([UIAlertController class],
                    @selector(alertControllerWithTitle:message:preferredStyle:),
                    @selector(sst_alertControllerWithTitle:message:preferredStyle:));
    SSTSwizzleClass([UIAlertAction class],
                    @selector(actionWithTitle:style:handler:),
                    @selector(sst_actionWithTitle:style:handler:));
}
