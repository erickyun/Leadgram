TARGET := iphone:clang:18.6:14.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES := Telegram Nicegram Swiftgram Turrit Vartagram Nagram
include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = PrivacyControls
PrivacyControls_FILES = PrivacyControls.m
PrivacyControls_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
PrivacyControls_FRAMEWORKS = Foundation UIKit
include $(THEOS_MAKE_PATH)/library.mk
