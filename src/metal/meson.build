metal = get_option('metal')
metal = metal.require(host_machine.system() == 'darwin',
                      error_message: 'Metal requires an Apple platform')

if metal.allowed()
  metal = metal.require(add_languages('objc', native: false, required: metal))
endif

metal_deps = dependency('appleframeworks', modules: ['Metal', 'Foundation'],
                        required: metal)
metal = metal.require(metal_deps.found())

components.set('metal', metal.allowed())
if metal.allowed()
  # Mirror the project-wide C warning setup for the Objective-C sources
  add_project_arguments(build_opts + c_opts, language: 'objc')
  build_deps += metal_deps
  tests += 'metal.c'
  sources += [
    'metal/context.m',
    'metal/formats.m',
    'metal/gpu.m',
  ]
else
  sources += 'metal/stubs.c'
endif
