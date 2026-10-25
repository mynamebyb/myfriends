TARGET := iphone:clang:latest:13.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GameRecorderV1
GameRecorderV1_FILES = src/GameRecorder.xm
GameRecorderV1_CFLAGS = -fobjc-arc -std=gnu++11 -Wno-deprecated-declarations -Wno-unused-variable -Wno-arc-performSelector-leaks
GameRecorderV1_FRAMEWORKS = Foundation UIKit AVFoundation Metal MetalKit MetalPerformanceShaders CoreVideo CoreMedia Photos
GameRecorderV1_LDFLAGS = -Wno-unused-dylib

include $(THEOS_MAKE_PATH)/library.mk
