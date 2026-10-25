TARGET := iphone:clang:16.5:13.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GameRecorder
GameRecorder_FILES = src/GameRecorder.xm
GameRecorder_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-arc-performSelector-leaks
GameRecorder_FRAMEWORKS = Foundation UIKit AVFoundation Metal MetalKit CoreVideo CoreMedia Photos
GameRecorder_LDFLAGS = -Wno-unused-dylib

include $(THEOS_MAKE_PATH)/library.mk
