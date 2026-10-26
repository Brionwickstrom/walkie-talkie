# Codec 2 (LGPL-2.1, https://github.com/drowe67/codec2, commit 310777b) for
# short voice clips over Meshtastic LoRa radios (v1.7.0). Only the speech
# codec is vendored (no FreeDV modems); the codebook*.c files were
# generated with codec2's generate_codebook tool. Built as its own shared
# library (libcodec2.so) and loaded from Dart with dart:ffi
# (lib/audio/codec2_ffi.dart).
cmake_minimum_required(VERSION 3.18)
project(walkie_codec2 C)

set(C2 ${CMAKE_CURRENT_SOURCE_DIR}/codec2)
add_library(codec2 SHARED
    ${C2}/codec2.c ${C2}/codec2_fft.c ${C2}/kiss_fft.c ${C2}/kiss_fftr.c
    ${C2}/lpc.c ${C2}/nlp.c ${C2}/phase.c ${C2}/postfilter.c
    ${C2}/quantise.c ${C2}/sine.c ${C2}/interp.c ${C2}/lsp.c ${C2}/mbest.c
    ${C2}/newamp1.c ${C2}/pack.c ${C2}/dump.c
    ${C2}/codebook.c ${C2}/codebookd.c ${C2}/codebookjmv.c ${C2}/codebookge.c
    ${C2}/codebooknewamp1.c ${C2}/codebooknewamp1_energy.c
    ${C2}/codebooknewamp2.c ${C2}/codebooknewamp2_energy.c)
target_include_directories(codec2 PRIVATE ${C2})
target_compile_options(codec2 PRIVATE -O2 -w)
target_link_libraries(codec2 m)
# Android 15+ 16 KB page size devices.
target_link_options(codec2 PRIVATE "-Wl,-z,max-page-size=16384")
