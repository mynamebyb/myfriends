TARGET := iphone:clang:latest:15.0
ARCHS = arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GameRecorder
GameRecorder_FILES = src/GameRecorder.xm vendor/litehook/litehook.c
# 对所有源文件安全的 flag（纯 C 的 litehook.c 也会吃这些）
GameRecorder_CFLAGS = -Wno-deprecated-declarations -Wno-unused-variable -Wno-arc-performSelector-leaks
# 仅 ObjC++（.xm）生效：ARC + C++11，避免污染纯 C 编译
GameRecorder_OBJCCFLAGS = -fobjc-arc -std=gnu++11
GameRecorder_FRAMEWORKS = Foundation UIKit AVFoundation AudioToolbox Metal MetalKit MetalPerformanceShaders CoreVideo CoreMedia Photos
GameRecorder_LDFLAGS = -Wno-unused-dylib

include $(THEOS_MAKE_PATH)/library.mk
