TARGET := iphone:clang:latest:13.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GameRecorder_takeone
GameRecorder_takeone_FILES = src/GameRecorder.xm
GameRecorder_takeone_CFLAGS = -fobjc-arc -std=gnu++11 -Wno-deprecated-declarations -Wno-unused-variable -Wno-arc-performSelector-leaks
GameRecorder_takeone_FRAMEWORKS = Foundation UIKit AVFoundation Metal MetalKit MetalPerformanceShaders CoreVideo CoreMedia Photos
GameRecorder_takeone_LDFLAGS = -Wno-unused-dylib

include $(THEOS_MAKE_PATH)/library.mk
