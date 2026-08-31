TARGET := iphone:clang:latest:16.1
ARCHS = arm64 arm64e
FINALPACKAGE = 1
DEBUG = 0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AIInputStatusSpringBoard
AIInputStatusSpringBoard_FILES = AIInputStatusSpringBoard.m
AIInputStatusSpringBoard_CFLAGS = -fobjc-arc
AIInputStatusSpringBoard_FRAMEWORKS = Foundation CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

include $(THEOS_MAKE_PATH)/aggregate.mk
