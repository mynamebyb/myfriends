TARGET := iphone:clang:latest:13.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GameRecorder
GameRecorder_FILES = src/GameRecorder.xm fishhook.c
GameRecorder_CFLAGS = -fobjc-arc -std=gnu++11 -Wno-deprecated-declarations -Wno-unused-variable -Wno-arc-performSelector-leaks
GameRecorder_FRAMEWORKS = Foundation UIKit AVFoundation Metal MetalKit MetalPerformanceShaders CoreVideo CoreMedia Photos AudioToolbox
GameRecorder_LDFLAGS = -Wno-unused-dylib

include $(THEOS_MAKE_PATH)/library.mk
