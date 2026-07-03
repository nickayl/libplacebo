metal = get_option('metal')
metal = metal.require(host_machine.system() == 'darwin',
                      error_message: 'Metal requires an Apple platform')

if metal.allowed()
  metal = metal.require(add_languages('objc', native: false, required: metal))
endif

metal_deps = dependency('appleframeworks', modules: ['Metal', 'Foundation'],
                        required: metal)
metal = metal.require(metal_deps.found())

# SPIRV-Cross provides the SPIR-V -> MSL cross-compilation for the shader path
metal_spvc = disabler()
if metal.allowed()
  metal_spvc = dependency('spirv-cross-c-shared', version: '>=0.29.0', required: false)
  if not metal_spvc.found()
    # Homebrew ships only the static spirv-cross-c, whose pkg-config file does
    # not declare the sibling archives it needs at link time
    metal_spvc = dependency('spirv-cross-c', version: '>=0.29.0', required: metal)
    if metal_spvc.found()
      spvc_libdir = metal_spvc.get_variable(pkgconfig: 'libdir', default_value: '')
      spvc_extra = []
      foreach l : ['spirv-cross-msl', 'spirv-cross-hlsl', 'spirv-cross-glsl',
                   'spirv-cross-reflect', 'spirv-cross-cpp', 'spirv-cross-util',
                   'spirv-cross-core']
        spvc_extra += cxx.find_library(l, dirs: spvc_libdir, required: false)
      endforeach
      metal_spvc = declare_dependency(dependencies: [metal_spvc] + spvc_extra)
    endif
  endif
  metal = metal.require(metal_spvc.found())
endif

components.set('metal', metal.allowed())
if metal.allowed()
  # Mirror the project-wide C warning setup for the Objective-C sources
  add_project_arguments(build_opts + c_opts, language: 'objc')
  build_deps += [metal_deps, metal_spvc]
  tests += 'metal.c'
  sources += [
    'metal/context.m',
    'metal/formats.m',
    'metal/gpu.m',
    'metal/gpu_buf.m',
    'metal/gpu_pass.m',
    'metal/gpu_tex.m',
  ]
else
  sources += 'metal/stubs.c'
endif
