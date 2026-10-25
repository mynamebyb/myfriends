ARCHS = arm64
TARGET := iphone:clang:latest:13.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = HideLabelOnRecord
HideLabelOnRecord_FILES = src/HideLabelOnRecord.xm
HideLabelOnRecord_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
HideLabelOnRecord_FRAMEWORKS = Foundation UIKit
# 纯 ObjC-Runtime 实现，不链接 CydiaSubstrate/ElleKit
HideLabelOnRecord_LDFLAGS = -Wno-unused-dylib

include $(THEOS_MAKE_PATH)/library.mk
