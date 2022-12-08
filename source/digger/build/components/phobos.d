module digger.build.components.phobos;

import digger.build.components;
import digger.build.manager;

/// Phobos import files.
/// In older versions of D, Druntime depended on Phobos modules.
final class PhobosIncludes : Component
{
	protected @property override string submoduleName() { return "phobos"; }
	protected @property override string[] sourceDependencies() { return []; }
	protected @property override string[] dependencies() { return []; }
	protected @property override string configString() { return null; }

	protected override void performStage()
	{
		foreach (f; ["std", "etc", "crc32.d"])
			if (buildPath(sourceDir, f).exists)
				cp(
					buildPath(sourceDir, f),
					buildPath(stageDir , "import", f),
				);
	}
}

/// Phobos library and imports.
final class Phobos : Component
{
	protected @property override string submoduleName    () { return "phobos"; }
	protected @property override string[] sourceDependencies() { return []; }
	protected @property override string[] dependencies() { return ["druntime", "dmd"]; }

	struct Config
	{
		/// The default target model on this platform.
		version (Windows)
			enum defaultModel = "32";
		else
		version (D_LP64)
			enum defaultModel = "64";
		else
			enum defaultModel = "32";

		/// Target comma-separated models ("32", "64", and on Windows, "32mscoff").
		/// Controls the models of the built Phobos and Druntime libraries.
		string model = defaultModel;

		@property string[] models() { return model.split(","); } /// Get/set `model` as list.
		@property void models(string[] value) { this.model = value.join(","); } /// ditto

		/// Build debug versions of Druntime / Phobos.
		bool debugLib;
	}

	protected @property override string configString()
	{
		static struct FullConfig
		{
			string model;
			string[] makeArgs;
		}

		return FullConfig(
			config.build.components.common.model,
			config.build.components.common.makeArgs,
		).toJson();
	}

	private string[] targets;

	protected override void performBuild()
	{
		getComponent("dmd").needSource();
		getComponent("dmd").needInstalled();
		getComponent("druntime").needBuild();

		targets = null;

		foreach (model; config.build.components.common.models)
		{
			// Clean up old object files with mismatching model.
			// Necessary for a consecutive 32/64 build.
			version (Windows)
			{
				foreach (de; dirEntries(sourceDir.buildPath("etc", "c", "zlib"), "*.obj", SpanMode.shallow))
				{
					auto data = cast(ubyte[])read(de.name);

					string fileModel;
					if (data.length < 4)
						fileModel = "invalid";
					else
					if (data[0] == 0x80)
						fileModel = "32"; // OMF
					else
					if (data[0] == 0x01 && data[0] == 0x4C)
						fileModel = "32mscoff"; // COFF - IMAGE_FILE_MACHINE_I386
					else
					if (data[0] == 0x86 && data[0] == 0x64)
						fileModel = "64"; // COFF - IMAGE_FILE_MACHINE_AMD64
					else
						fileModel = "unknown";

					if (fileModel != model)
					{
						log("Cleaning up object file '%s' with mismatching model (file is %s, building %s)".format(de.name, fileModel, model));
						remove(de.name);
					}
				}
			}

			auto env = baseEnvironment;
			needCC(env, model);

			string phobosMakeFileName = findMakeFile(sourceDir, makeFileNameModel(model));
			string phobosMakeFullName = sourceDir.buildPath(phobosMakeFileName);

			version (Windows)
			{
				auto lib = "phobos%s.lib".format(modelSuffix(model));
				runMake(env, model, lib);
				enforce(sourceDir.buildPath(lib).exists);
				targets ~= ["phobos%s.lib".format(modelSuffix(model))];
			}
			else
			{
				string[] makeArgs;
				if (phobosMakeFullName.readText().canFind("DRUNTIME = $(DRUNTIME_PATH)/lib/libdruntime-$(OS)$(MODEL).a") &&
					getComponent("druntime").sourceDir.buildPath("lib").dirEntries(SpanMode.shallow).walkLength == 0 &&
					exists(getComponent("druntime").sourceDir.buildPath("generated")))
				{
					auto dir = getComponent("druntime").sourceDir.buildPath("generated");
					auto aFile  = dir.dirEntries("libdruntime.a", SpanMode.depth);
					if (!aFile .empty) makeArgs ~= ["DRUNTIME="   ~ aFile .front];
					auto soFile = dir.dirEntries("libdruntime.so.a", SpanMode.depth);
					if (!soFile.empty) makeArgs ~= ["DRUNTIMESO=" ~ soFile.front];
				}
				runMake(env, model, makeArgs);
				targets ~= sourceDir
					.buildPath("generated")
					.dirEntries(SpanMode.depth)
					.filter!(de => de.name.endsWith(".a") || de.name.endsWith(".so"))
					.map!(de => de.name.relativePath(sourceDir))
					.array()
				;
			}
		}
	}

	protected override void performStage()
	{
		assert(targets.length, "Phobos stage without build");
		foreach (lib; targets)
			cp(
				buildPath(sourceDir, lib),
				buildPath(stageDir , "lib", lib.baseName()),
			);
	}

	protected override void performTest()
	{
		getComponent("druntime").needBuild(true);
		getComponent("phobos").needBuild(true);
		getComponent("dmd").needInstalled();

		foreach (model; config.build.components.common.models)
		{
			auto env = baseEnvironment;
			needCC(env, model);
			version (Windows)
			{
				getComponent("curl").needInstalled();
				getComponent("curl").updateEnv(env);

				// Patch out std.datetime unittest to work around Digger test
				// suite failure on AppVeyor due to Windows time zone changes
				auto stdDateTime = buildPath(sourceDir, "std", "datetime.d");
				if (stdDateTime.exists && !stdDateTime.readText().canFind("Altai Standard Time"))
				{
					auto m = stdDateTime.readText();
					m = m
						.replace(`assert(tzName !is null, format("TZName which is missing: %s", winName));`, ``)
						.replace(`assert(tzDatabaseNameToWindowsTZName(tzName) !is null, format("TZName which failed: %s", tzName));`, `{}`)
						.replace(`assert(windowsTZNameToTZDatabaseName(tzName) !is null, format("TZName which failed: %s", tzName));`, `{}`)
					;
					stdDateTime.write(m);
					submodule.saveFileState("std/datetime.d");
				}

				if (model == "32")
					getComponent("extras").needInstalled();
			}
			runMake(env, model, "unittest");
		}
	}

	private final void runMake(ref Environment env, string model, string[] makeArgs...)
	{
		// Work around https://github.com/dlang/druntime/pull/2438
		bool quotePaths = !(isVersion!"Windows" && model != "32" && sourceDir.buildPath("win64.mak").readText().canFind(`"$(CC)"`));

		string[] args =
			getMake(env) ~
			["-f", makeFileNameModel(model)] ~
			makeArgs ~
			["DMD=" ~ dmd] ~
			config.build.components.common.makeArgs ~
			(config.build.components.common.debugLib ? ["BUILD=debug"] : []) ~
			getPlatformMakeVars(env, model, quotePaths) ~
			dMakeArgs;
		run(args, env.vars, sourceDir);
	}
}
