.PHONY: *
examples := 1_triangle 2_textures 3_3D 4_indirect_triangles 5_compute_shaders 6_deferred_async_load 7_raytracing third_party/dear_imgui
glsl_flags :=

ifeq ($(OS),Windows_NT)
exe_extension := .exe
else
exe_extension :=
endif

default: vercheck build_vma build_imgui build

# Verifies that all dependencies are installed
vercheck:
	make --version
	premake5 --version
	odin version
	glslangValidator --version
	slangc -v
	python3 --version
	git -v

clean_example:
	rm -rf examples/$(example)/shaders/*.spv
	rm -rf examples/$(example)/shaders/*.glsl

# Checks that all examples compile without errors
check:
	$(foreach example,$(examples),$(MAKE) check_example example=$(example);)

check_example:
	odin check examples/$(example)

# Builds all examples
build:
	$(foreach example,$(examples),$(MAKE) build_example example=$(example);)

build_example:
	$(MAKE) clean_example example=$(example)
	$(MAKE) shader_musl example=$(example)
	odin build examples/$(example) -debug "-out=build/$(subst /,_,$(example))$(exe_extension)"

run_example:
	$(MAKE) clean_example example=$(example)
	$(MAKE) shader_musl example=$(example)
	odin run examples/$(example) -debug -keep-executable "-out=build/$(subst /,_,$(example))$(exe_extension)"

run_example_slang:
	$(MAKE) shader_slang example=$(example)
	odin run examples/$(example) -debug -keep-executable "-out=build/$(subst /,_,$(example))$(exe_extension)"

# Builds the gpu_compiler
compiler:
	odin build gpu_compiler -debug -out=build/gpu_compiler$(exe_extension)

# ==== Native dependencies ====

ifeq ($(OS),Windows_NT)
premake:
	@echo "Compiling $(folder) with premake arguments $(arguments)"
	powershell -NoProfile -Command "cmd /c 'call \"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat\" && cd $(folder) && premake5 $(arguments) vs2022 && cd build && build.bat'"
else
premake:
	echo "Not supported on this platform"
	exit 1
endif

build_vma:
	$(MAKE) premake folder=gpu/vma arguments=--vk-version=3

build_imgui:
	$(MAKE) premake folder=examples/third_party/dear_imgui/odin-imgui arguments=--backends=sdl3,vulkan

# ==== Shaders ====

# Builds the MUSL shaders for all examples
shaders_musl:
	$(foreach example,$(examples),$(MAKE) shader_musl example=$(example);)

# Compiles MUSL shaders for one example via gpu_compiler + glslangValidator.
shader_musl: compiler
	@set -e; \
	if [ -z "$(example)" ]; then \
		echo "Usage: make shader_musl example=<example_name>"; \
		exit 1; \
	fi; \
	dir="examples/$(example)"; \
	if [ ! -d "$$dir/shaders" ]; then \
		echo "No shaders directory found: $$dir/shaders"; \
		exit 1; \
	fi; \
	for musl in "$$dir"/shaders/*.musl; do \
		[ -e "$$musl" ] || continue; \
		echo "Compiling $$musl"; \
		./build/gpu_compiler$(exe_extension) "$$musl"; \
		glsl="$${musl%.musl}.glsl"; \
		spv="$${musl%.musl}.spv"; \
		glslangValidator $(glsl_flags) -V "$$glsl" -o "$$spv"; \
	done

# Builds the Slang shaders for all examples
shaders_slang:
	$(foreach example,$(examples),$(MAKE) shader_slang example=$(example);)

# Compiles Slang shaders for one example and validates SPIR-V output.
shader_slang:
	echo "Compiling Slang shaders for $(example)";
	if [ -z "$(example)" ]; then \
		echo "Usage: make shader_slang example=<example_name>"; \
		exit 1; \
	fi; \
	dir="examples/$(example)"; \
	if [ ! -d "$$dir/shaders" ]; then \
		echo "No shaders directory found: $$dir/shaders"; \
		exit 1; \
	fi; \
	for slang in "$$dir"/shaders/*.slang; do \
		[ -e "$$slang" ] || continue; \
		base="$${slang%.slang}"; \
		echo "Compiling $$slang"; \
		if [ -f "$$base.vert.musl" ]; then \
			slangc -target spirv -target glsl -fvk-use-scalar-layout -force-glsl-scalar-layout -validate-ir -no-mangle -entry vertexMain -stage vertex "$$slang" -o "$$base.vert.spv" -o "$$base.vert.glsl"; \
			spirv-val "$$base.vert.spv" --relax-block-layout --scalar-block-layout --target-env vulkan1.3; \
		fi; \
		if [ -f "$$base.frag.musl" ]; then \
			slangc -target spirv -target glsl -fvk-use-scalar-layout -force-glsl-scalar-layout -validate-ir -no-mangle -entry fragmentMain -stage fragment "$$slang" -o "$$base.frag.spv" -o "$$base.frag.glsl"; \
			spirv-val "$$base.frag.spv" --relax-block-layout --scalar-block-layout --target-env vulkan1.3; \
		fi; \
		if [ -f "$$base.comp.musl" ]; then \
			slangc -target spirv -target glsl -fvk-use-scalar-layout -force-glsl-scalar-layout -validate-ir -no-mangle -entry computeMain -stage compute "$$slang" -o "$$base.comp.spv" -o "$$base.comp.glsl"; \
			spirv-val "$$base.comp.spv" --relax-block-layout --scalar-block-layout --target-env vulkan1.3; \
		fi; \
	done

# ==== Individual examples ====

example1:
	$(MAKE) run_example example=1_triangle

example2:
	$(MAKE) run_example example=2_textures

example3:
	$(MAKE) run_example example=3_3D

example4:
	$(MAKE) run_example example=4_indirect_triangles

example5:
	$(MAKE) run_example example=5_compute_shaders

example6:
	$(MAKE) run_example example=6_deferred_async_load

example7:
	$(MAKE) run_example example=7_raytracing

example_imgui:
	$(MAKE) run_example example=third_party/dear_imgui