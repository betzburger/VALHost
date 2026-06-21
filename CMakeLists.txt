cmake_minimum_required(VERSION 3.22)
project(VALHost VERSION 1.0.0 LANGUAGES C CXX OBJCXX Swift)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_Swift_LANGUAGE_VERSION 5)

# JUCE framework directory
set(JUCE_DIR "/Volumes/X9-Mac-mini/Backup/peterbetz/JUCE")
add_subdirectory(${JUCE_DIR} ./juce)

# Create GUI App target
juce_add_gui_app(VALHost
    PRODUCT_NAME "VALHost"
    COMPANY_NAME "VAL"
    BUNDLE_ID "com.val.valhost"
    IS_COPY_STEP_ENABLED TRUE
    ICON_BIG "${CMAKE_CURRENT_SOURCE_DIR}/Source/icon.png"
)

# App Sources
target_sources(VALHost PRIVATE
    Source/AudioEngine.h
    Source/AudioEngine.cpp
    Source/JuceInitializer.h
    Source/JuceInitializer.cpp
    Source/VALHostEngineBridge.h
    Source/VALHostEngineBridge.mm
    Source/VALHost-Bridging-Header.h
    Source/VALHostApp.swift
    Source/ContentView.swift
)

# Compile definitions to enable AU, VST3, and LV2 plugin hosting
target_compile_definitions(VALHost PRIVATE
    JUCE_PLUGINHOST_AU=1
    JUCE_PLUGINHOST_VST3=1
    JUCE_PLUGINHOST_LV2=1
    JUCE_PLUGINHOST_VST=0 # VST2 is deprecated and disabled
    JUCE_SILENCE_XCODE_DEPRECATION_WARNINGS=1
    JUCE_DISABLE_ASSERTIONS=1
    # Keep assertion logging OFF. JUCE's LV2 lookup constructs a juce::File from a
    # plugin URI (juce_LV2PluginFormat.cpp), which trips a harmless "Illegal absolute
    # path" assertion for every LV2 plug-in during a scan. With JUCE_LOG_ASSERTIONS=1
    # that floods the console with hundreds of lines. =0 silences that spam; the
    # behaviour is benign (the lookup falls back to URI matching).
    JUCE_LOG_ASSERTIONS=0
)

# Link modules
target_link_libraries(VALHost PRIVATE
    juce::juce_audio_basics
    juce::juce_audio_devices
    juce::juce_audio_formats
    juce::juce_audio_processors
    juce::juce_audio_utils
    juce::juce_core
    juce::juce_data_structures
    juce::juce_events
    juce::juce_graphics
    juce::juce_gui_basics
    juce::juce_gui_extra
)

juce_generate_juce_header(VALHost)

# Configure Swift Bridging Header and Info.plist properties
set_target_properties(VALHost PROPERTIES
    Swift_OBJC_BRIDGING_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/Source/VALHost-Bridging-Header.h"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Source/Info.plist"
)

# Tell the compiler where to find headers, and explicitly pass the bridging header to swiftc.
# NOTE: We intentionally do NOT pass an explicit -sdk here. The Swift sources must build
# against the same SDK as the C++/Obj-C++ sources (Xcode's active SDK); hard-coding the
# CommandLineTools SDK caused a cross-SDK mismatch in the Xcode build.
target_include_directories(VALHost PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/Source")
target_compile_options(VALHost PRIVATE $<$<COMPILE_LANGUAGE:Swift>:-import-objc-header;${CMAKE_CURRENT_SOURCE_DIR}/Source/VALHost-Bridging-Header.h>)

# Add weak framework link options for Metal and MetalKit directly to target link options to bypass CMake's library resolution
target_link_options(VALHost PRIVATE
    "SHELL:-Xlinker -weak_framework -Xlinker Metal"
    "SHELL:-Xlinker -weak_framework -Xlinker MetalKit"
)

# Translate -framework flags in JUCE modules to Swift-compatible -Xlinker syntax and strip -weak_framework flags (handled directly above)
set(juce_targets
    juce_core
    juce_events
    juce_graphics
    juce_data_structures
    juce_gui_basics
    juce_gui_extra
    juce_audio_basics
    juce_audio_devices
    juce_audio_formats
    juce_audio_processors
    juce_audio_utils
)

foreach(t IN LISTS juce_targets)
    if(TARGET ${t})
        get_target_property(libs ${t} INTERFACE_LINK_LIBRARIES)
        if(libs)
            set(new_libs "")
            set(next_is_framework FALSE)
            set(next_skip FALSE)
            foreach(lib IN LISTS libs)
                if(next_skip)
                    set(next_skip FALSE)
                elseif(next_is_framework)
                    list(APPEND new_libs "-Xlinker" "${lib}")
                    set(next_is_framework FALSE)
                elseif(lib MATCHES "Metal")
                    # Skip Metal-related libraries
                elseif(lib STREQUAL "-weak_framework")
                    # Skip separate -weak_framework and its next argument (which will be Metal/MetalKit)
                    set(next_skip TRUE)
                elseif(lib MATCHES "^-weak_framework +(.*)$")
                    # Skip combined -weak_framework Metal/MetalKit
                elseif(lib MATCHES "^-framework +(.*)$")
                    list(APPEND new_libs "-Xlinker" "-framework" "-Xlinker" "${CMAKE_MATCH_1}")
                elseif(lib STREQUAL "-framework")
                    list(APPEND new_libs "-Xlinker" "-framework")
                    set(next_is_framework TRUE)
                else()
                    list(APPEND new_libs "${lib}")
                endif()
            endforeach()
            set_target_properties(${t} PROPERTIES INTERFACE_LINK_LIBRARIES "${new_libs}")
        endif()
    endif()
endforeach()
