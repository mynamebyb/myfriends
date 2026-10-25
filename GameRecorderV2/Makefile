TARGET := iphone:clang:latest:13.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GameRecorderV2
GameRecorderV2_FILES = src/GameRecorder.xm
GameRecorderV2_CFLAGS = -fobjc-arc -std=gnu++11 -Wno-deprecated-declarations -Wno-unused-variable -Wno-arc-performSelector-leaks
GameRecorderV2_FRAMEWORKS = Foundation UIKit AVFoundation Metal MetalKit MetalPerformanceShaders CoreVideo CoreMedia Photos
GameRecorderV2_LDFLAGS = -Wno-unused-dylib

include $(THEOS_MAKE_PATH)/library.mk
