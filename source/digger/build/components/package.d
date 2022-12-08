module digger.build.components;

import ae.utils.json;

import digger.build.manager;

/// Base class for a D component.
class Component
{
	/// Name of this component, as registered in DManager.components AA.
	string name;

	/// Corresponding subproject repository name.
	@property abstract string submoduleName();
	/// Corresponding subproject repository.
	@property DManager.ManagedRepository submodule() { return getSubmodule(submoduleName); }

	/// Configuration applicable to multiple components.
	/// These settings can be set for all components,
	/// as well as overridden for individual components.
	struct CommonConfig
	{
		/// Additional make parameters, e.g. "HOST_CC=g++48"
		@JSONOptional string[] makeArgs;

		/// Additional environment variables.
		/// Supports %VAR% expansion - see applyEnv.
		@JSONOptional string[string] environment;

		/// Optional cache key.
		/// Can be used to force a rebuild and bypass the cache for one build.
		@JSONOptional string cacheKey;
	}

	/// A string description of this component's configuration.
	abstract @property string configString();

	/// Commit in the component's repo from which to build this component.
	@property string commit() { return incrementalBuild ? "incremental" : getComponentCommit(name); }

	/// The components the source code of which this component depends on.
	/// Used for calculating the cache key.
	@property abstract string[] sourceDependencies();

	/// The components the state and configuration of which this component depends on.
	/// Used for calculating the cache key.
	@property abstract string[] dependencies();

	/// This metadata is saved to a .json file,
	/// and is also used to calculate the cache key.
	struct Metadata
	{
		int cacheVersion; ///
		string name; ///
		string commit; ///
		string configString; ///
		string[] sourceDepCommits; ///
		Metadata[] dependencyMetadata; ///
		@JSONOptional string cacheKey; ///
	}

	Metadata getMetadata()
	{
		return Metadata(
			cacheVersion,
			name,
			commit,
			configString,
			sourceDependencies.map!(
				dependency => getComponent(dependency).commit
			).array(),
			dependencies.map!(
				dependency => getComponent(dependency).getMetadata()
			).array(),
			config.build.cacheKey,
		);
	} /// ditto

	void saveMetaData(string target)
	{
		std.file.write(buildPath(target, "digger-metadata.json"), getMetadata().toJson());
		// Use a separate file to avoid double-encoding JSON
		std.file.write(buildPath(target, "digger-config.json"), configString);
	} /// ditto

	/// Calculates the cache key, which should be unique and immutable
	/// for the same source, build parameters, and build algorithm.
	string getBuildID()
	{
		auto configBlob = getMetadata().toJson() ~ configString;
		return "%s-%s-%s".format(
			name,
			commit,
			configBlob.getDigestString!MD5().toLower(),
		);
	}

	@property string sourceDir() { return submodule.git.path; } ///

	/// Directory to which built files are copied to.
	/// This will then be atomically added to the cache.
	protected string stageDir;

	/// Prepare the source checkout for this component.
	/// Usually needed by other components.
	void needSource(bool needClean = false)
	{
		tempError++; scope(success) tempError--;

		if (incrementalBuild)
			return;
		if (!submoduleName)
			return;

		bool needHead;
		if (needClean)
			needHead = true;
		else
		{
			// It's OK to run tests with a dirty worktree (i.e. after a build).
			needHead = commit != submodule.getHead();
		}

		if (needHead)
		{
			foreach (component; getSubmoduleComponents(submoduleName))
				component.haveBuild = false;
			submodule.needHead(commit);
		}
		submodule.clean = false;
	}

	private bool haveBuild;

	/// Build the component in-place, as needed,
	/// without moving the built files anywhere.
	void needBuild(bool clean = true)
	{
		if (haveBuild) return;
		scope(success) haveBuild = true;

		log("needBuild: " ~ getBuildID());

		needSource(clean);

		prepareEnv();

		log("Building " ~ getBuildID());
		performBuild();
		log(getBuildID() ~ " built OK!");
	}

	/// Set up / clean the build environment.
	private void prepareEnv()
	{
		// Nuke any additional directories cloned by makefiles
		if (!incrementalBuild)
		{
			getMetaRepo().git.run(["clean", "-ffdx"]);

			foreach (dir; [tmpDir, homeDir])
			{
				if (dir.exists && !dir.dirEntries(SpanMode.shallow).empty)
					log("Clearing %s ...".format(dir));
				dir.recreateEmptyDirectory();
			}
		}

		// Set up compiler wrappers.
		recreateEmptyDirectory(binDir);
		version (linux)
		{
			foreach (cc; ["cc", "gcc", "c++", "g++"])
			{
				auto fileName = binDir.buildPath(cc);
				write(fileName, q"EOF
#!/bin/sh
set -eu

tool=$(basename "$0")
next=/usr/bin/$tool
tmpdir=${TMP:-/tmp}
flagfile=$tmpdir/nopie-flag-$tool

if [ ! -e "$flagfile" ]
then
echo 'Testing for -no-pie...' 1>&2
testfile=$tmpdir/test-$$.c
echo 'int main(){return 0;}' > $testfile
if $next -no-pie -c -o$testfile.o $testfile
then
	printf "%s" "-no-pie" > "$flagfile".$$.tmp
	mv "$flagfile".$$.tmp "$flagfile"
else
	touch "$flagfile"
fi
rm -f "$testfile" "$testfile.o"
fi

exec "$next" $(cat "$flagfile") "$@"
EOF");
				setAttributes(fileName, octal!755);
			}
		}
	}

	private bool haveInstalled;

	/// Build and "install" the component to buildDir as necessary.
	void needInstalled()
	{
		if (haveInstalled) return;
		scope(success) haveInstalled = true;

		auto buildID = getBuildID();
		log("needInstalled: " ~ buildID);

		needCacheEngine();
		if (cacheEngine.haveEntry(buildID))
		{
			log("Cache hit!");
			if (cacheEngine.listFiles(buildID).canFind(unbuildableMarker))
				throw new Exception(buildID ~ " was cached as unbuildable");
		}
		else
		{
			log("Cache miss.");

			auto tempDir = buildPath(config.local.workDir, "temp");
			if (tempDir.exists)
				tempDir.removeRecurse();
			stageDir = buildPath(tempDir, buildID);
			stageDir.mkdirRecurse();

			bool failed = false;
			tempError = 0;

			// Save the results to cache, failed or not
			void saveToCache()
			{
				// Use a separate function to work around
				// "cannot put scope(success) statement inside scope(exit)"

				int currentTempError = tempError;

				// Treat cache errors an environmental errors
				// (for when needInstalled is invoked to build a dependency)
				tempError++; scope(success) tempError--;

				// tempDir might be removed by a dependency's build failure.
				if (!tempDir.exists)
					log("Not caching %s dependency build failure.".format(name));
				else
				// Don't cache failed build results due to temporary/environment problems
				if (failed && currentTempError > 0)
				{
					log("Not caching %s build failure due to temporary/environment error.".format(name));
					rmdirRecurse(tempDir);
				}
				else
				// Don't cache failed build results during delve
				if (failed && !cacheFailures)
				{
					log("Not caching failed %s build.".format(name));
					rmdirRecurse(tempDir);
				}
				else
				if (cacheEngine.haveEntry(buildID))
				{
					// Can happen due to force==true
					log("Already in cache.");
					rmdirRecurse(tempDir);
				}
				else
				{
					log("Saving to cache.");
					saveMetaData(stageDir);
					cacheEngine.add(buildID, stageDir);
					rmdirRecurse(tempDir);
				}
			}

			scope (exit)
				saveToCache();

			// An incomplete build is useless, nuke the directory
			// and create a new one just for the "unbuildable" marker.
			scope (failure)
			{
				failed = true;
				if (stageDir.exists)
				{
					rmdirRecurse(stageDir);
					mkdir(stageDir);
					buildPath(stageDir, unbuildableMarker).touch();
				}
			}

			needBuild();

			performStage();
		}

		install();
	}

	/// Build the component in-place, without moving the built files anywhere.
	void performBuild() {}

	/// Place resulting files to stageDir
	void performStage() {}

	/// Update the environment post-install, to allow
	/// building components that depend on this one.
	void updateEnv(ref DManager.Environment env) {}

	/// Copy build results from cacheDir to buildDir
	void install()
	{
		log("Installing " ~ getBuildID());
		needCacheEngine().extract(getBuildID(), buildDir, de => !de.baseName.startsWith("digger-"));
	}

	/// Prepare the dependencies then run the component's tests.
	void test()
	{
		log("Testing " ~ getBuildID());

		needSource();

		submodule.clean = false;
		performTest();
		log(getBuildID() ~ " tests OK!");
	}

	/// Run the component's tests.
	void performTest() {}

protected final:
	// Utility declarations for component implementations

	string modelSuffix(string model) { return model == "32" ? "" : model; }
	version (Windows)
	{
		enum string makeFileName = "win32.mak";
		string makeFileNameModel(string model)
		{
			if (model == "32mscoff")
				model = "64";
			return "win"~model~".mak";
		}
		enum string binExt = ".exe";
	}
	else
	{
		enum string makeFileName = "posix.mak";
		string makeFileNameModel(string model) { return "posix.mak"; }
		enum string binExt = "";
	}

	version (Windows)
		enum platform = "windows";
	else
	version (linux)
		enum platform = "linux";
	else
	version (OSX)
		enum platform = "osx";
	else
	version (FreeBSD)
		enum platform = "freebsd";
	else
		static assert(false);

	/// Returns the command for the make utility.
	string[] getMake(ref const DManager.Environment env)
	{
		version (FreeBSD)
			enum makeProgram = "gmake"; // GNU make
		else
		version (Posix)
			enum makeProgram = "make"; // GNU make
		else
			enum makeProgram = "make"; // DigitalMars make
		return [env.vars.get("MAKE", makeProgram)];
	}

	/// Returns the path to the built dmd executable.
	@property string dmd() { return buildPath(buildDir, "bin", "dmd" ~ binExt).absolutePath(); }

	/// Escape a path for d_do_test's very "special" criteria.
	/// Spaces must be escaped, but there must be no double-quote at the end.
	private static string dDoTestEscape(string str)
	{
		return str.replaceAll(re!`\\([^\\ ]*? [^\\]*)(?=\\)`, `\"$1"`);
	}

	unittest
	{
		assert(dDoTestEscape(`C:\Foo boo bar\baz quuz\derp.exe`) == `C:\"Foo boo bar"\"baz quuz"\derp.exe`);
	}

	string[] getPlatformMakeVars(ref const DManager.Environment env, string model, bool quote = true)
	{
		string[] args;

		args ~= "MODEL=" ~ model;

		version (Windows)
			if (model != "32")
			{
				args ~= "VCDIR="  ~ env.deps.vsDir.buildPath("VC").absolutePath();
				args ~= "SDKDIR=" ~ env.deps.sdkDir.absolutePath();

				// Work around https://github.com/dlang/druntime/pull/2438
				auto quoteStr = quote ? `"` : ``;
				args ~= "CC=" ~ quoteStr ~ env.deps.vsDir.buildPath("VC", "bin", msvcModelDir(model), "cl.exe").absolutePath() ~ quoteStr;
				args ~= "LD=" ~ quoteStr ~ env.deps.vsDir.buildPath("VC", "bin", msvcModelDir(model), "link.exe").absolutePath() ~ quoteStr;
				args ~= "AR=" ~ quoteStr ~ env.deps.vsDir.buildPath("VC", "bin", msvcModelDir(model), "lib.exe").absolutePath() ~ quoteStr;
			}

		return args;
	}

	@property string[] gnuMakeArgs()
	{
		string[] args;
		if (config.local.makeJobs)
		{
			if (config.local.makeJobs == "auto")
			{
				import std.parallelism, std.conv;
				args ~= "-j" ~ text(totalCPUs);
			}
			else
			if (config.local.makeJobs == "unlimited")
				args ~= "-j";
			else
				args ~= "-j" ~ config.local.makeJobs;
		}
		return args;
	}

	@property string[] dMakeArgs()
	{
		version (Windows)
			return null; // On Windows, DigitalMars make is used for all makefiles except the dmd test suite
		else
			return gnuMakeArgs;
	}

	/// Older versions did not use the posix.mak/win32.mak convention.
	static string findMakeFile(string dir, string fn)
	{
		version (OSX)
			if (!dir.buildPath(fn).exists && dir.buildPath("osx.mak").exists)
				return "osx.mak";
		version (Posix)
			if (!dir.buildPath(fn).exists && dir.buildPath("linux.mak").exists)
				return "linux.mak";
		return fn;
	}

	void needCC(ref DManager.Environment env, string model, string dmcVer = null)
	{
		version (Windows)
		{
			needDMC(env, dmcVer); // We need DMC even for 64-bit builds (for DM make)
			if (model != "32")
				needVC(env, model);
		}
	}

	void run(const(string)[] args, in string[string] newEnv, string dir)
	{
		// Apply user environment
		auto env = applyEnv(newEnv, config.build.environment);

		// Temporarily apply PATH from newEnv to our process,
		// so process creation lookup can use it.
		string oldPath = std.process.environment["PATH"];
		scope (exit) std.process.environment["PATH"] = oldPath;
		std.process.environment["PATH"] = env["PATH"];

		// Apply timeout setting
		if (config.local.timeout)
			args = ["timeout", config.local.timeout.text] ~ args;

		foreach (name, value; env)
			log("Environment: " ~ name ~ "=" ~ value);
		log("Working directory: " ~ dir);
		log("Running: " ~ escapeShellCommand(args));

		auto status = spawnProcess(args, env, std.process.Config.newEnv, dir).wait();
		enforce(status == 0, "Command %s failed with status %d".format(args, status));
	}
}
