module digger.build.components.dmd;

import digger.build.components;
import digger.build.manager;

/// The dmd executable
final class DMD : Component
{
	protected @property override string submoduleName  () { return "dmd"; }
	protected @property override string[] sourceDependencies() { return []; }
	protected @property override string[] dependencies() { return []; }

	/// DMD configuration file name for the current platform.
	version (Windows)
		enum configFileName = "sc.ini";
	else
		enum configFileName = "dmd.conf";

	/// DMD build configuration.
	struct Config
	{
		/// Overrides for the common configuration.
		@JSONOptional CommonConfig common;

		/// Whether to build a debug DMD.
		/// Debug builds are faster to build,
		/// but run slower.
		@JSONOptional bool debugDMD = false;

		/// Whether to build a release DMD.
		/// Mutually exclusive with debugDMD.
		@JSONOptional bool releaseDMD = false;

		/// Model for building DMD itself (on Windows).
		/// Can be used to build a 64-bit DMD, to avoid 4GB limit.
		@JSONOptional string dmdModel = CommonConfig.defaultModel;

		/// How to build DMD versions written in D.
		/// We can either download a pre-built binary DMD
		/// package, or build an  earlier version from source
		/// (e.g. starting with the last C++-only version.)
		struct Bootstrap
		{
			/// Whether to download a pre-built D version,
			/// or build one from source. If set, then build
			/// from source according to the value of ver,
			@JSONOptional bool fromSource = false;

			/// Version specification.
			/// When building from source, syntax can be defined
			/// by outer application (see parseSpec method);
			/// When the bootstrapping compiler is not built from source,
			/// it is understood as a version number, such as "v2.070.2",
			/// which also doubles as a tag name.
			/// By default (when set to null), an appropriate version
			/// is selected automatically.
			@JSONOptional string ver = null;

			/// Build configuration for the compiler used for bootstrapping.
			/// If not set, then use the default build configuration.
			/// Used when fromSource is set.
			@JSONOptional DManager.Config.Build* build;
		}
		@JSONOptional Bootstrap bootstrap; /// ditto

		/// Use Visual C++ to build DMD instead of DMC.
		/// Currently, this is a hack, as msbuild will consult the system
		/// registry and use the system-wide installation of Visual Studio.
		/// Only relevant for older versions, as newer versions are written in D.
		@JSONOptional bool useVC;
	}

	protected @property override string configString()
	{
		static struct FullConfig
		{
			Config config;
			string[] makeArgs;

			// Include the common models as well as the DMD model (from config).
			// Necessary to ensure the correct sc.ini is generated on Windows
			// (we don't want to pull in MSVC unless either DMD or Phobos are
			// built as 64-bit, but also we can't reuse a DMD build with 32-bit
			// DMD and Phobos for a 64-bit Phobos build because it won't have
			// the VC vars set up in its sc.ini).
			// Possibly refactor the compiler configuration to a separate
			// component in the future to avoid the inefficiency of rebuilding
			// DMD just to generate a different sc.ini.
			@JSONOptional string commonModel = Component.CommonConfig.defaultModel;
		}

		return FullConfig(
			config.build.components.dmd,
			config.build.components.common.makeArgs,
			config.build.components.common.model,
		).toJson();
	} ///

	/// Name of the Visual Studio build configuration to use.
	@property string vsConfiguration() { return config.build.components.dmd.debugDMD ? "Debug" : "Release"; }
	/// Name of the Visual Studio build platform to use.
	@property string vsPlatform     () { return config.build.components.dmd.dmdModel == "64" ? "x64" : "Win32"; }

	protected override void performBuild()
	{
		// We need an older DMC for older DMD versions
		string dmcVer = null;
		auto idgen = buildPath(sourceDir, "src", "idgen.c");
		if (idgen.exists && idgen.readText().indexOf(`{ "alignof" },`) >= 0)
			dmcVer = "850";

		auto env = baseEnvironment;
		needCC(env, config.build.components.dmd.dmdModel, dmcVer); // Need VC too for VSINSTALLDIR

		auto srcDir = buildPath(sourceDir, "src");
		string dmdMakeFileName = findMakeFile(srcDir, makeFileName);
		string dmdMakeFullName = srcDir.buildPath(dmdMakeFileName);

		if (buildPath(sourceDir, "src", "idgen.d").exists ||
			buildPath(sourceDir, "src", "ddmd", "idgen.d").exists ||
			buildPath(sourceDir, "src", "ddmd", "mars.d").exists ||
			buildPath(sourceDir, "src", "dmd", "mars.d").exists)
		{
			// Need an older DMD for bootstrapping.
			string dmdVer = "v2.067.1";
			if (sourceDir.buildPath("test/compilable/staticforeach.d").exists)
				dmdVer = "v2.068.0";
			version (Windows)
				if (config.build.components.dmd.dmdModel != Component.CommonConfig.defaultModel)
					dmdVer = "v2.070.2"; // dmd/src/builtin.d needs core.stdc.math.fabsl. 2.068.2 generates a dmd which crashes on building Phobos
			if (sourceDir.buildPath("src/dmd/backend/dvec.d").exists) // 2.079 is needed since 2.080
				dmdVer = "v2.079.0";
			needDMD(env, dmdVer);

			// Go back to our commit (in case we bootstrapped from source).
			needSource(true);
			submodule.clean = false;
		}

		if (config.build.components.dmd.useVC) // Mostly obsolete, see useVC ddoc
		{
			version (Windows)
			{
				needVC(env, config.build.components.dmd.dmdModel);

				env.vars["PATH"] = env.vars["PATH"] ~ pathSeparator ~ env.deps.hostDC.dirName;

				auto solutionFile = `dmd_msc_vs10.sln`;
				if (!exists(srcDir.buildPath(solutionFile)))
					solutionFile = `vcbuild\dmd.sln`;
				if (!exists(srcDir.buildPath(solutionFile)))
					throw new Exception("Can't find Visual Studio solution file");

				return run(["msbuild", "/p:Configuration=" ~ vsConfiguration, "/p:Platform=" ~ vsPlatform, solutionFile], env.vars, srcDir);
			}
			else
				throw new Exception("Can only use Visual Studio on Windows");
		}

		version (Windows)
			auto scRoot = env.deps.dmcDir.absolutePath();

		string modelFlag = config.build.components.dmd.dmdModel;
		if (dmdMakeFullName.readText().canFind("MODEL=-m32"))
			modelFlag = "-m" ~ modelFlag;

		version (Windows)
		{
			auto m = dmdMakeFullName.readText();
			m = m
				// A make argument is insufficient,
				// because of recursive make invocations
				.replace(`CC=\dm\bin\dmc`, `CC=dmc`)
				.replace(`SCROOT=$D\dm`, `SCROOT=` ~ scRoot)
				// Debug crashes in build.d
				.replaceAll(re!(`^(	\$\(HOST_DC\) .*) (build\.d)$`, "m"), "$1 -g $2")
			;
			dmdMakeFullName.write(m);
		}
		else
		{
			auto m = dmdMakeFullName.readText();
			m = m
				// Fix hard-coded reference to gcc as linker
				.replace(`gcc -m32 -lstdc++`, `g++ -m32 -lstdc++`)
				.replace(`gcc $(MODEL) -lstdc++`, `g++ $(MODEL) -lstdc++`)
				// Fix compilation of older versions of go.c with GCC 6
				.replace(`-Wno-deprecated`, `-Wno-deprecated -Wno-narrowing`)
			;
			// Fix pthread linker error
			version (linux)
				m = m.replace(`-lpthread`, `-pthread`);
			dmdMakeFullName.write(m);
		}

		submodule.saveFileState("src/" ~ dmdMakeFileName);

		version (Windows)
		{
			auto buildDFileName = "build.d";
			auto buildDPath = srcDir.buildPath(buildDFileName);
			if (buildDPath.exists)
			{
				auto buildD = buildDPath.readText();
				buildD = buildD
					// https://github.com/dlang/dmd/pull/10491
					// Needs WBEM PATH entry, and also fails under Wine as its wmic outputs UTF-16.
					.replace(`["wmic", "OS", "get", "OSArchitecture"].execute.output`, isWin64 ? `"64-bit"` : `"32-bit"`)
				;
				buildDPath.write(buildD);
				submodule.saveFileState("src/" ~ buildDFileName);
			}
		}

		// Fix compilation error of older DMDs with glibc >= 2.25
		version (linux)
		{{
			auto fn = srcDir.buildPath("root", "port.c");
			if (fn.exists)
			{
				fn.write(fn.readText
					.replace(`#include <bits/mathdef.h>`, `#include <complex.h>`)
					.replace(`#include <bits/nan.h>`, `#include <math.h>`)
				);
				submodule.saveFileState(fn.relativePath(sourceDir));
			}
		}}

		// Fix alignment issue in older DMDs with GCC >= 7
		// See https://issues.dlang.org/show_bug.cgi?id=17726
		version (Posix)
		{
			foreach (fn; [srcDir.buildPath("tk", "mem.c"), srcDir.buildPath("ddmd", "tk", "mem.c")])
				if (fn.exists)
				{
					fn.write(fn.readText.replace(
							// `#if defined(__llvm__) && (defined(__GNUC__) || defined(__clang__))`,
							// `#if defined(__GNUC__) || defined(__clang__)`,
							`numbytes = (numbytes + 3) & ~3;`,
							`numbytes = (numbytes + 0xF) & ~0xF;`
					));
					submodule.saveFileState(fn.relativePath(sourceDir));
				}
		}

		string[] extraArgs, targets;
		version (Posix)
		{
			if (config.build.components.dmd.debugDMD)
				extraArgs ~= "DEBUG=1";
			if (config.build.components.dmd.releaseDMD)
				extraArgs ~= "ENABLE_RELEASE=1";
		}
		else
		{
			if (config.build.components.dmd.debugDMD)
				targets ~= [];
			else
			if (config.build.components.dmd.releaseDMD && dmdMakeFullName.readText().canFind("reldmd"))
				targets ~= ["reldmd"];
			else
				targets ~= ["dmd"];
		}

		version (Windows)
		{
			if (config.build.components.dmd.dmdModel != CommonConfig.defaultModel)
			{
				dmdMakeFileName = "win64.mak";
				dmdMakeFullName = srcDir.buildPath(dmdMakeFileName);
				enforce(dmdMakeFullName.exists, "dmdModel not supported for this DMD version");
				extraArgs ~= "DMODEL=-m" ~ config.build.components.dmd.dmdModel;
				if (config.build.components.dmd.dmdModel == "32mscoff")
				{
					auto objFiles = dmdMakeFullName.readText().splitLines().filter!(line => line.startsWith("OBJ_MSVC="));
					enforce(!objFiles.empty, "Can't find OBJ_MSVC in win64.mak");
					extraArgs ~= "OBJ_MSVC=" ~ objFiles.front.findSplit("=")[2].split().filter!(obj => obj != "ldfpu.obj").join(" ");
				}
			}
		}

		// Avoid HOST_DC reading ~/dmd.conf
		string hostDC = env.deps.hostDC;
		version (Posix)
		if (hostDC && needConfSwitch())
		{
			auto dcProxy = buildPath(config.local.workDir, "host-dc-proxy.sh");
			std.file.write(dcProxy, escapeShellCommand(["exec", hostDC, "-conf=" ~ buildPath(dirName(hostDC), configFileName)]) ~ ` "$@"`);
			setAttributes(dcProxy, octal!755);
			hostDC = dcProxy;
		}

		run(getMake(env) ~ [
				"-f", dmdMakeFileName,
				"MODEL=" ~ modelFlag,
				"HOST_DC=" ~ hostDC,
			] ~ config.build.components.common.makeArgs ~ dMakeArgs ~ extraArgs ~ targets,
			env.vars, srcDir
		);
	}

	protected override void performStage()
	{
		if (config.build.components.dmd.useVC)
		{
			foreach (ext; [".exe", ".pdb"])
				cp(
					buildPath(sourceDir, "src", "vcbuild", vsPlatform, vsConfiguration, "dmd_msc" ~ ext),
					buildPath(stageDir , "bin", "dmd" ~ ext),
				);
		}
		else
		{
			string dmdPath = buildPath(sourceDir, "generated", platform, "release", config.build.components.dmd.dmdModel, "dmd" ~ binExt);
			if (!dmdPath.exists)
				dmdPath = buildPath(sourceDir, "src", "dmd" ~ binExt); // legacy
			enforce(dmdPath.exists && dmdPath.isFile, "Can't find built DMD executable");

			cp(
				dmdPath,
				buildPath(stageDir , "bin", "dmd" ~ binExt),
			);
		}

		version (Windows)
		{
			auto env = baseEnvironment;
			needCC(env, config.build.components.dmd.dmdModel);
			foreach (model; config.build.components.common.models)
				needCC(env, model);

			auto ini = q"EOS
[Environment]
LIB=%@P%\..\lib
DFLAGS="-I%@P%\..\import"
DMC=__DMC__
LINKCMD=%DMC%\link.exe
EOS"
			.replace("__DMC__", env.deps.dmcDir.buildPath(`bin`).absolutePath())
		;

			if (env.deps.vsDir && env.deps.sdkDir)
			{
				ini ~= q"EOS

[Environment64]
LIB=%@P%\..\lib
DFLAGS=%DFLAGS% -L/OPT:NOICF
VSINSTALLDIR=__VS__\
VCINSTALLDIR=%VSINSTALLDIR%VC\
PATH=%PATH%;%VCINSTALLDIR%\bin\__MODELDIR__;%VCINSTALLDIR%\bin
WindowsSdkDir=__SDK__
LINKCMD=%VCINSTALLDIR%\bin\__MODELDIR__\link.exe
LIB=%LIB%;%VCINSTALLDIR%\lib\amd64
LIB=%LIB%;%WindowsSdkDir%\Lib\x64

[Environment32mscoff]
LIB=%@P%\..\lib
DFLAGS=%DFLAGS% -L/OPT:NOICF
VSINSTALLDIR=__VS__\
VCINSTALLDIR=%VSINSTALLDIR%VC\
PATH=%PATH%;%VCINSTALLDIR%\bin
WindowsSdkDir=__SDK__
LINKCMD=%VCINSTALLDIR%\bin\link.exe
LIB=%LIB%;%VCINSTALLDIR%\lib
LIB=%LIB%;%WindowsSdkDir%\Lib
EOS"
					.replace("__VS__"      , env.deps.vsDir .absolutePath())
					.replace("__SDK__"     , env.deps.sdkDir.absolutePath())
					.replace("__MODELDIR__", msvcModelDir("64"))
				;
			}

			buildPath(stageDir, "bin", configFileName).write(ini);
		}
		else version (OSX)
		{
			auto ini = q"EOS
[Environment]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib"
EOS";
			buildPath(stageDir, "bin", configFileName).write(ini);
		}
		else version (linux)
		{
			auto ini = q"EOS
[Environment32]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib" -L--export-dynamic

[Environment64]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib" -L--export-dynamic -fPIC
EOS";
			buildPath(stageDir, "bin", configFileName).write(ini);
		}
		else
		{
			auto ini = q"EOS
[Environment]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib" -L--export-dynamic
EOS";
			buildPath(stageDir, "bin", configFileName).write(ini);
		}
	}

	protected override void updateEnv(ref Environment env)
	{
		// Add the DMD we built for Phobos/Druntime/Tools
		env.vars["PATH"] = buildPath(buildDir, "bin").absolutePath() ~ pathSeparator ~ env.vars["PATH"];
	}

	protected override void performTest()
	{
		foreach (dep; ["dmd", "druntime", "phobos"])
			getComponent(dep).needBuild(true);

		foreach (model; config.build.components.common.models)
		{
			auto env = baseEnvironment;
			version (Windows)
			{
				// In this order so it uses the MSYS make
				needCC(env, model);
				needMSYS(env);

				disableCrashDialog();
			}

			auto makeArgs = getMake(env) ~ config.build.components.common.makeArgs ~ getPlatformMakeVars(env, model) ~ gnuMakeArgs;
			version (Windows)
			{
				makeArgs ~= ["OS=win" ~ model[0..2], "SHELL=bash"];
				if (model == "32")
				{
					auto extrasDir = needExtras();
					// The autotester seems to pass this via environment. Why does that work there???
					makeArgs ~= "LIB=" ~ extrasDir.buildPath("localextras-windows", "dmd2", "windows", "lib") ~ `;..\..\phobos`;
				}
				else
				{
					// Fix path for d_do_test and its special escaping (default is the system VS2010 install)
					// We can't use the same syntax in getPlatformMakeVars because win64.mak uses "CC=\$(CC32)"\""
					auto cl = env.deps.vsDir.buildPath("VC", "bin", msvcModelDir(model), "cl.exe");
					foreach (ref arg; makeArgs)
						if (arg.startsWith("CC="))
							arg = "CC=" ~ dDoTestEscape(cl);
				}
			}

			version (test)
			{
				// Only try a few tests during CI runs, to check for
				// platform integration and correct invocation.
				// For this purpose, the C++ ABI tests will do nicely.
				makeArgs ~= [
				//	"test_results/runnable/cppa.d.out", // https://github.com/dlang/dmd/pull/5686
					"test_results/runnable/cpp_abi_tests.d.out",
					"test_results/runnable/cabi1.d.out",
				];
			}

			run(makeArgs, env.vars, sourceDir.buildPath("test"));
		}
	}
}
