#import "MDBackedTextStorage.h"

@implementation MDBackedTextStorage

- (instancetype)init {
    if ((self = [super init])) {
        _backing = [[NSMutableAttributedString alloc] init];
    }
    return self;
}

- (NSUInteger)length {
    return _backing.length;
}

// The backing's own string, live, as NSConcreteTextStorage answers: AppKit
// asks during layout, once per line break. A Swift override answered with a
// bridged copy of the whole document, made again after every edit.
- (NSString *)string {
    return _backing.string;
}

- (NSDictionary<NSAttributedStringKey, id> *)attributesAtIndex:(NSUInteger)location effectiveRange:(NSRangePointer)range {
    if (_backing.length == 0) {
        if (range) *range = NSMakeRange(0, 0);
        return @{};
    }
    return [_backing attributesAtIndex:location effectiveRange:range];
}

- (NSDictionary<NSAttributedStringKey, id> *)attributesAtIndex:(NSUInteger)location longestEffectiveRange:(NSRangePointer)range inRange:(NSRange)rangeLimit {
    if (_backing.length == 0) {
        if (range) *range = NSMakeRange(0, 0);
        return @{};
    }
    return [_backing attributesAtIndex:location longestEffectiveRange:range inRange:rangeLimit];
}

- (nullable id)attribute:(NSAttributedStringKey)name atIndex:(NSUInteger)location effectiveRange:(NSRangePointer)range {
    if (_backing.length == 0) {
        if (range) *range = NSMakeRange(0, 0);
        return nil;
    }
    return [_backing attribute:name atIndex:location effectiveRange:range];
}

- (nullable id)attribute:(NSAttributedStringKey)name atIndex:(NSUInteger)location longestEffectiveRange:(NSRangePointer)range inRange:(NSRange)rangeLimit {
    // Attribute fixing looks for glyph info from the edit out to both ends of
    // the document, walking every run, on every keystroke. Styling sets each
    // edited line's attributes whole before fixing runs, so there is never
    // any to find.
    if ([name isEqualToString:NSGlyphInfoAttributeName]) {
        if (range) *range = rangeLimit;
        return nil;
    }
    if (_backing.length == 0) {
        if (range) *range = NSMakeRange(0, 0);
        return nil;
    }
    return [_backing attribute:name atIndex:location longestEffectiveRange:range inRange:rangeLimit];
}

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)string {
    [self beginEditing];
    [_backing replaceCharactersInRange:range withString:string];
    [self edited:NSTextStorageEditedCharacters range:range changeInLength:(NSInteger)string.length - (NSInteger)range.length];
    [self endEditing];
}

- (void)setAttributes:(nullable NSDictionary<NSAttributedStringKey, id> *)attributes range:(NSRange)range {
    [self beginEditing];
    [_backing setAttributes:attributes range:range];
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
    [self endEditing];
}

- (void)addBackingAttributes:(id)attributes range:(NSRange)range {
    [_backing addAttributes:attributes range:range];
}

@end
