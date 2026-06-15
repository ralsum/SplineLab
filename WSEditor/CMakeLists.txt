cmake_minimum_required(VERSION 3.20)

project(WSEditor LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(WIN32)
  add_executable(WSEditor WIN32
    src/main.cpp
  )
  target_link_options(WSEditor PRIVATE
    $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-municode>
    $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-static-libgcc>
    $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-static-libstdc++>
  )
else()
  add_executable(WSEditor
    src/main_cli.cpp
  )
  set_target_properties(WSEditor PROPERTIES
    OUTPUT_NAME wse
  )
endif()

target_compile_definitions(WSEditor PRIVATE
  UNICODE
  _UNICODE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
)

target_compile_options(WSEditor PRIVATE
  $<$<CXX_COMPILER_ID:MSVC>:/W4 /EHsc>
  $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wall -Wextra -Wpedantic>
)

if(WIN32)
  target_link_libraries(WSEditor PRIVATE
    comdlg32
    comctl32
    gdi32
    ole32
    shell32
    user32
  )
else()
  install(TARGETS WSEditor
    RUNTIME DESTINATION bin
  )
endif()
