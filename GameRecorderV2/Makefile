TARGET := iphone:clang:latest:13.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GameRecorder_taketwo
GameRecorder_taketwo_FILES = src/GameRecorder.xm
GameRecorder_taketwo_CFLAGS = -fobjc-arc -std=gnu++11 -Wno-deprecated-declarations -Wno-unused-variable -Wno-arc-performSelector-leaks
GameRecorder_taketwo_FRAMEWORKS = Foundation UIKit AVFoundation Metal MetalKit MetalPerformanceShaders CoreVideo CoreMedia Photos
GameRecorder_taketwo_LDFLAGS = -Wno-unused-dylib

include $(THEOS_MAKE_PATH)/library.mk
