/**
 * Code to manage D repositories and their dependencies.
 */

module digger.build.manager;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.json : parseJSON;
import std.path;
import std.process : spawnProcess, wait, escapeShellCommand;
import std.range;
import std.regex;
import std.string;
import std.typecons;

import ae.net.github.rest;
import ae.sys.file;
import ae.sys.git;
import ae.utils.aa;
import ae.utils.array;
import ae.utils.digest;
import ae.utils.json;
import ae.utils.meta;
import ae.utils.regex;
import ae.utils.sini : IniFragment;

import digger.build.cache;
import digger.build.components;
import digger.build.repo;

// Standard components
static import digger.build.components.dmd;
static import digger.build.components.druntime;
static import digger.build.components.phobos;
static import digger.build.components.rdmd;
static import digger.build.components.tools;
static import digger.build.components.website;
static import digger.build.components.extras;
static import digger.build.components.curl;
static import digger.build.components.dub;

private alias ensureDirExists = ae.sys.file.ensureDirExists;

version (Windows) private
{
	import ae.sys.install.dmc;
	import ae.sys.install.msys;
	import ae.sys.install.vs;

	import ae.sys.windows.misc;

	extern(Windows) void SetErrorMode(int);
}

import ae.sys.install.dmd;
import ae.sys.install.git;
import ae.sys.install.kindlegen;

static import std.process;

/// Class which manages D repositories and their dependencies.
/// An application will typically need one instance across its lifetime.
class DManager : ICacheHost
{
	/// Build configuration
	struct BuildConfig
	{
		/// Explicitly enable or disable a component.
		bool[string] buildComponent;

		/// Returns a list of all enabled components, whether
		/// they're enabled explicitly or by default.
		string[] getEnabledComponentNames()
		{
			foreach (componentName; buildComponent.byKey)
				enforce(allComponents.canFind(componentName), "Unknown component: " ~ componentName);
			return allComponents
				.filter!(componentName =>
					buildComponent.get(componentName, defaultComponents.canFind(componentName)))
				.array
				.dup;
		}

		/// Common configuration defaults for all components.
		Component.CommonConfig common;

		/// Components' build configuration
		IniFragment!string[string] components;
	}

	// **************************** Configuration ****************************

	/// Machine-local configuration
	/// These settings should not affect the build output.
	struct Local
	{
		/// Location for the checkout, temporary files, etc.
		string workDir;

		/// If present, passed to GNU make via -j parameter.
		/// Can also be "auto" or "unlimited".
		string makeJobs;

		/// Don't get latest updates from GitHub.
		bool offline;

		/// How to cache built files.
		string cache;

		/// Maximum execution time, in seconds, of any single
		/// command.
		int timeout;

		/// API token to access the GitHub REST API (optional).
		string githubToken;
	}
	Local localConfig; /// ditto

	// Behavior options that generally depend on the host program.

	/// Whether we should cache failed builds.
	bool cacheFailures = true;

	/// Get a specific subdirectory of the work directory.
	@property string subDir(string name)() { return buildPath(config.local.workDir, name); }

	alias repoDir    = subDir!"repos";       /// The git repository location.
	alias dlDir      = subDir!"dl";          /// The directory for downloaded software.
	alias githubDir  = subDir!"github-cache";/// For the GitHub API cache.

	/// This number increases with each incompatible change to cached data.
	enum cacheVersion = 3;

	/// Returns the path to cached data for the given cache engine
	/// (as in `config.local.cache`).
	string cacheEngineDir(string engineName)
	{
		// Keep compatibility with old cache paths
		string engineDirName =
			engineName.isOneOf("directory", "true") ? "cache"      :
			engineName.isOneOf("", "none", "false") ? "temp-cache" :
			"cache-" ~ engineName;
		return buildPath(
			config.local.workDir,
			engineDirName,
			"v%d".format(cacheVersion),
		);
	}

	/// Executable file name suffix for the current platform.
	version (Windows)
		enum string binExt = ".exe";
	else
		enum string binExt = "";

	/// DMD configuration file name for the current platform.
	version (Windows)
		enum configFileName = "sc.ini";
	else
		enum configFileName = "dmd.conf";

	// **************************** Repositories *****************************

	/// Base class for a `DManager` Git repository.
	class DManagerRepository : ManagedRepository
	{
		this()
		{
			this.offline = config.local.offline;
		} ///

		protected override void log(string s) { return this.outer.log(s); }
	}

	/// Sub-project repositories.
	class SubmoduleRepository : DManagerRepository
	{
		string dir; /// Full path to the repository.

		protected override Git getRepo()
		{
			auto git = Git(dir);
			withInstaller({
				auto gitExecutable = gitInstaller.requireInstalled().getExecutable("git");
				assert(git.commandPrefix[0] == "git");
				git.commandPrefix[0] = gitExecutable;
			});
			return git;
		}
	}

	private SubmoduleRepository[string] submodules; /// ditto

	ManagedRepository getSubmodule(string name)
	{
		assert(name, "This component is not associated with a submodule");
		if (name !in submodules)
		{
			auto repo = new SubmoduleRepository();
			repo.dir = buildPath(repoDir, name);

			if (!repo.dir.exists)
			{
				log("Cloning repository %s...".format(name));

				void cloneTo(string target)
				{
					withInstaller({
						import ae.sys.cmd : run;
						auto gitExecutable = gitInstaller.requireInstalled().getExecutable("git");
						run([gitExecutable, "clone", "--mirror", url, target]);
					});
					
					
				}
				atomic!cloneTo(repo.dir);

				getMetaRepo().git.run(["submodule", "update", "--init", name]);
			}

			submodules[name] = repo;
		}

		return submodules[name];
	} /// ditto

	// ***************************** Components ******************************

	private int tempError;

	private Component[string] components;

	/// Retrieve a component by name
	/// (as it would occur in `config.build.components.enable`).
	Component getComponent(string name)
	{
		if (name !in components)
		{
			Component c;

			switch (name)
			{
				case "dmd":
					c = new DMD();
					break;
				case "phobos-includes":
					c = new PhobosIncludes();
					break;
				case "druntime":
					c = new Druntime();
					break;
				case "phobos":
					c = new Phobos();
					break;
				case "rdmd":
					c = new RDMD();
					break;
				case "tools":
					c = new Tools();
					break;
				case "website":
					c = new Website();
					break;
				case "extras":
					c = new Extras();
					break;
				case "curl":
					c = new Curl();
					break;
				case "dub":
					c = new Dub();
					break;
				default:
					throw new Exception("Unknown component: " ~ name);
			}

			c.name = name;
			return components[name] = c;
		}

		return components[name];
	}

	/// Retrieve components built from the given submodule name.
	Component[] getSubmoduleComponents(string submoduleName)
	{
		return components
			.byValue
			.filter!(component => component.submoduleName == submoduleName)
			.array();
	}

	// ***************************** GitHub API ******************************

	private GitHub github;

	private ref GitHub needGitHub()
	{
		if (github is GitHub.init)
		{
			github.log = &this.log;
			github.token = config.local.githubToken;
			github.cache = new class GitHub.ICache
			{
				final string cacheFileName(string key)
				{
					return githubDir.buildPath(getDigestString!MD5(key).toLower());
				}

				string get(string key)
				{
					auto fn = cacheFileName(key);
					return fn.exists ? fn.readText : null;
				}

				void put(string key, string value)
				{
					githubDir.ensureDirExists;
					std.file.write(cacheFileName(key), value);
				}
			};
			github.offline = config.local.offline;
		}
		return github;
	}

	// ****************************** Building *******************************

	private SubmoduleState submoduleState;
	private bool incrementalBuild;

	/// Returns the name of the cache engine being used.
	@property string cacheEngineName()
	{
		if (incrementalBuild)
			return "none";
		else
			return config.local.cache;
	}

	private string getComponentCommit(string componentName)
	{
		auto submoduleName = getComponent(componentName).submoduleName;
		auto commit = submoduleState.submoduleCommits.get(submoduleName, null);
		enforce(commit, "Unknown commit to build for component %s (submodule %s)"
			.format(componentName, submoduleName));
		return commit;
	}

	static const string[] defaultComponents = ["dmd", "druntime", "phobos-includes", "phobos", "rdmd"]; /// Components enabled by default.
	static const string[] additionalComponents = ["tools", "website", "extras", "curl", "dub"]; /// Components disabled by default.
	static const string[] allComponents = defaultComponents ~ additionalComponents; /// All components that may be enabled and built.

	/// Build the specified components according to the specified configuration.
	void build(SubmoduleState submoduleState, bool incremental = false)
	{
		auto componentNames = config.build.components.getEnabledComponentNames();
		log("Building components %-(%s, %)".format(componentNames));

		this.components = null;
		this.submoduleState = submoduleState;
		this.incrementalBuild = incremental;

		if (buildDir.exists)
			buildDir.removeRecurse();
		enforce(!buildDir.exists);

		scope(exit) if (cacheEngine) cacheEngine.finalize();

		foreach (componentName; componentNames)
			getComponent(componentName).needInstalled();
	}

	/// Shortcut for begin + build
	void buildRev(string rev)
	{
		auto submoduleState = begin(rev);
		build(submoduleState);
	}

	/// Simply check out the source code for the given submodules.
	void checkout(SubmoduleState submoduleState)
	{
		auto componentNames = config.build.components.getEnabledComponentNames();
		log("Checking out components %-(%s, %)".format(componentNames));

		this.components = null;
		this.submoduleState = submoduleState;
		this.incrementalBuild = false;

		foreach (componentName; componentNames)
			getComponent(componentName).needSource(true);
	}

	/// Run all tests for the current checkout (like rebuild).
	void test(bool incremental = true)
	{
		auto componentNames = config.build.components.getEnabledComponentNames();
		log("Testing components %-(%s, %)".format(componentNames));

		if (incremental)
		{
			this.components = null;
			this.submoduleState = SubmoduleState(null);
			this.incrementalBuild = true;
		}

		foreach (componentName; componentNames)
			getComponent(componentName).test();
	}

	/// Check if the given build is cached.
	bool isCached(SubmoduleState submoduleState)
	{
		this.components = null;
		this.submoduleState = submoduleState;

		needCacheEngine();
		foreach (componentName; config.build.components.getEnabledComponentNames())
			if (!cacheEngine.haveEntry(getComponent(componentName).getBuildID()))
				return false;
		return true;
	}

	/// Returns the `isCached` state for all commits in the history of the given ref.
	bool[string] getCacheState(string[string][string] history)
	{
		log("Enumerating cache entries...");
		auto cacheEntries = needCacheEngine().getEntries().toSet();

		this.components = null;
		auto componentNames = config.build.components.getEnabledComponentNames();
		auto components = componentNames.map!(componentName => getComponent(componentName)).array;
		auto requiredSubmodules = components
			.map!(component => chain(component.name.only, component.sourceDependencies, component.dependencies))
			.joiner
			.map!(componentName => getComponent(componentName).submoduleName)
			.array.sort().uniq().array
		;

		log("Collating cache state...");
		bool[string] result;
		foreach (commit, submoduleCommits; history)
		{
			import ae.utils.meta : I;
			this.submoduleState.submoduleCommits = submoduleCommits;
			result[commit] =
				requiredSubmodules.all!(submoduleName => submoduleName in submoduleCommits) &&
				componentNames.all!(componentName =>
					getComponent(componentName).I!(component =>
						component.getBuildID() in cacheEntries
					)
				);
		}
		return result;
	}

	/// ditto
	bool[string] getCacheState(string[] refs)
	{
		auto history = getMetaRepo().getSubmoduleHistory(refs);
		return getCacheState(history);
	}

	// **************************** Dependencies *****************************

	private void withInstaller(void delegate() fun)
	{
		auto ourInstaller = new Installer(dlDir);
		ourInstaller.logger = &log;

		auto oldInstaller = .installer;
		.installer = ourInstaller;
		scope(exit) .installer = oldInstaller;
		fun();
	}

	/// Pull in a built DMD as configured.
	/// Note that this function invalidates the current repository state.
	void needDMD(ref Environment env, string dmdVer)
	{
		tempError++; scope(success) tempError--;

		auto numericVersion(string dmdVer)
		{
			assert(dmdVer.startsWith("v"));
			return dmdVer[1 .. $].splitter('.').map!(to!int).array;
		}

		// Nudge indicated version if we know it won't be usable on the current system.
		version (OSX)
		{
			enum minimalWithoutEnumerateTLV = "v2.088.0";
			if (numericVersion(dmdVer) < numericVersion(minimalWithoutEnumerateTLV) && !haveEnumerateTLV())
			{
				log("DMD " ~ dmdVer ~ " not usable on this system - using " ~ minimalWithoutEnumerateTLV ~ " instead.");
				dmdVer = minimalWithoutEnumerateTLV;
			}
		}

		// User setting overrides autodetection
		if (config.build.components.dmd.bootstrap.ver)
		{
			log("Using user-specified bootstrap DMD version " ~
				config.build.components.dmd.bootstrap.ver ~
				" instead of auto-detected version " ~ dmdVer ~ ".");
			dmdVer = config.build.components.dmd.bootstrap.ver;
		}

		if (config.build.components.dmd.bootstrap.fromSource)
		{
			log("Bootstrapping DMD " ~ dmdVer);

			auto bootstrapBuildConfig = config.build.components.dmd.bootstrap.build;

			// Back up and clear component state
			enum backupTemplate = q{
				auto VARBackup = this.VAR;
				this.VAR = typeof(VAR).init;
				scope(exit) this.VAR = VARBackup;
			};
			mixin(backupTemplate.replace(q{VAR}, q{components}));
			mixin(backupTemplate.replace(q{VAR}, q{config}));
			mixin(backupTemplate.replace(q{VAR}, q{submoduleState}));

			config.local = configBackup.local;
			if (bootstrapBuildConfig)
				config.build = *bootstrapBuildConfig;

			// Disable building rdmd in the bootstrap compiler by default
			if ("rdmd" !in config.build.components.enable)
				config.build.components.enable["rdmd"] = false;

			build(parseSpec(dmdVer));

			log("Built bootstrap DMD " ~ dmdVer ~ " successfully.");

			auto bootstrapDir = buildPath(config.local.workDir, "bootstrap");
			if (bootstrapDir.exists)
				bootstrapDir.removeRecurse();
			ensurePathExists(bootstrapDir);
			rename(buildDir, bootstrapDir);

			env.deps.hostDC = buildPath(bootstrapDir, "bin", "dmd" ~ binExt);
		}
		else
		{
			import std.ascii;
			log("Preparing DMD " ~ dmdVer);
			enforce(dmdVer.startsWith("v"), "Invalid DMD version spec for binary bootstrap. Did you forget to " ~
				((dmdVer.length && dmdVer[0].isDigit && dmdVer.contains('.')) ? "add a leading 'v'" : "enable fromSource") ~ "?");
			withInstaller({
				auto dmdInstaller = new DMDInstaller(dmdVer[1..$]);
				env.deps.hostDC = dmdInstaller.requireInstalled.getExecutable("dmd").absolutePath();
			});
		}

		log("hostDC=" ~ env.deps.hostDC);
	}

	protected void needKindleGen(ref Environment env)
	{
		withInstaller({
			env.vars = kindleGenInstaller.requireInstalled().getEnvironment(env.vars);
		});
	}

	version (Windows)
	protected void needMSYS(ref Environment env)
	{
		needInstaller();
		MSYS.msysCORE.requireLocal(false);
		MSYS.libintl.requireLocal(false);
		MSYS.libiconv.requireLocal(false);
		MSYS.libtermcap.requireLocal(false);
		MSYS.libregex.requireLocal(false);
		MSYS.coreutils.requireLocal(false);
		MSYS.bash.requireLocal(false);
		MSYS.make.requireLocal(false);
		MSYS.grep.requireLocal(false);
		MSYS.sed.requireLocal(false);
		MSYS.diffutils.requireLocal(false);
		env.vars["PATH"] = MSYS.bash.directory.buildPath("bin") ~ pathSeparator ~ env.vars["PATH"];
	}

	/// Get DMD unbuildable extras
	/// (proprietary DigitalMars utilities, 32-bit import libraries)
	protected string needExtras()
	{
		import ae.utils.meta : I, singleton;

		static class DExtrasInstaller : Package
		{
			protected @property override string name() { return "dmd-localextras"; }
			string url = "http://semitwist.com/download/app/dmd-localextras.7z";

			protected override void installImpl(string target)
			{
				url
					.I!save()
					.I!unpackTo(target);
			}

			static this()
			{
				urlDigests["http://semitwist.com/download/app/dmd-localextras.7z"] = "ef367c2d25d4f19f45ade56ab6991c726b07d3d9";
			}
		}

		alias extrasInstaller = singleton!DExtrasInstaller;

		string dir;
		withInstaller({
			dir = extrasInstaller.requireInstalled().directory;
		});
		return dir;
	}

	/// Get libcurl for Windows (DLL and import libraries)
	version (Windows)
	protected string needCurl()
	{
		import ae.utils.meta : I, singleton;

		static class DCurlInstaller : Installer
		{
			protected @property override string name() { return "libcurl-" ~ curlVersion; }
			string curlVersion = "7.47.1";
			@property string url() { return "http://downloads.dlang.org/other/libcurl-" ~ curlVersion ~ "-WinSSL-zlib-x86-x64.zip"; }

			protected override void installImpl(string target)
			{
				url
					.I!save()
					.I!unpackTo(target);
			}

			static this()
			{
				urlDigests["http://downloads.dlang.org/other/libcurl-7.47.1-WinSSL-zlib-x86-x64.zip"] = "4b8a7bb237efab25a96588093ae51994c821e097";
			}
		}

		alias curlInstaller = singleton!DCurlInstaller;

		needInstaller();
		curlInstaller.requireLocal(false);
		return curlInstaller.directory;
	}

	version (Windows)
	protected void needDMC(ref Environment env, string ver = null)
	{
		tempError++; scope(success) tempError--;

		needInstaller();

		auto dmc = ver ? new LegacyDMCInstaller(ver) : dmcInstaller;
		if (!dmc.installedLocally)
			log("Preparing DigitalMars C++ " ~ ver);
		dmc.requireLocal(false);
		env.deps.dmcDir = dmc.directory;

		auto binPath = buildPath(env.deps.dmcDir, `bin`).absolutePath();
		log("DMC=" ~ binPath);
		env.vars["DMC"] = binPath;
		env.vars["PATH"] = binPath ~ pathSeparator ~ env.vars.get("PATH", null);
	}

	version (Windows)
	auto getVSInstaller()
	{
		needInstaller();
		return vs2013community;
	}

	version (Windows)
	protected static string msvcModelStr(string model, string str32, string str64)
	{
		switch (model)
		{
			case "32":
				throw new Exception("Shouldn't need VC for 32-bit builds");
			case "64":
				return str64;
			case "32mscoff":
				return str32;
			default:
				throw new Exception("Unknown model: " ~ model);
		}
	}

	version (Windows)
	protected static string msvcModelDir(string model, string dir64 = "x86_amd64")
	{
		return msvcModelStr(model, null, dir64);
	}

	version (Windows)
	protected void needVC(ref Environment env, string model)
	{
		tempError++; scope(success) tempError--;

		auto vs = getVSInstaller();

		// At minimum, we want the C compiler (cl.exe) and linker (link.exe).
		vs["vc_compilercore86"].requireLocal(false); // Contains both x86 and x86_amd64 cl.exe
		vs["vc_compilercore86res"].requireLocal(false); // Contains clui.dll needed by cl.exe

		// Include files. Needed when using VS to build either DMD or Druntime.
		vs["vc_librarycore86"].requireLocal(false); // Contains include files, e.g. errno.h needed by Druntime

		// C runtime. Needed for all programs built with VC.
		vs[msvcModelStr(model, "vc_libraryDesktop_x86", "vc_libraryDesktop_x64")].requireLocal(false); // libcmt.lib

		// XP-compatible import libraries.
		vs["win_xpsupport"].requireLocal(false); // shell32.lib

		// MSBuild, for the useVC option
		if (config.build.components.dmd.useVC)
			vs["Msi_BuildTools_MSBuild_x86"].requireLocal(false); // msbuild.exe

		env.deps.vsDir  = vs.directory.buildPath("Program Files (x86)", "Microsoft Visual Studio 12.0").absolutePath();
		env.deps.sdkDir = vs.directory.buildPath("Program Files", "Microsoft SDKs", "Windows", "v7.1A").absolutePath();

		env.vars["PATH"] ~= pathSeparator ~ vs.modelBinPaths(msvcModelDir(model)).map!(path => vs.directory.buildPath(path).absolutePath()).join(pathSeparator);
		env.vars["VisualStudioVersion"] = "12"; // Work-around for problem fixed in dmd 38da6c2258c0ff073b0e86e0a1f6ba190f061e5e
		env.vars["VSINSTALLDIR"] = env.deps.vsDir ~ dirSeparator; // ditto
		env.vars["VCINSTALLDIR"] = env.deps.vsDir.buildPath("VC") ~ dirSeparator;
		env.vars["INCLUDE"] = env.deps.vsDir.buildPath("VC", "include") ~ ";" ~ env.deps.sdkDir.buildPath("Include");
		env.vars["LIB"] = env.deps.vsDir.buildPath("VC", "lib", msvcModelDir(model, "amd64")) ~ ";" ~ env.deps.sdkDir.buildPath("Lib", msvcModelDir(model, "x64"));
		env.vars["WindowsSdkDir"] = env.deps.sdkDir ~ dirSeparator;
		env.vars["Platform"] = "x64";
		env.vars["LINKCMD64"] = env.deps.vsDir.buildPath("VC", "bin", msvcModelDir(model), "link.exe"); // Used by dmd
		env.vars["MSVC_CC"] = env.deps.vsDir.buildPath("VC", "bin", msvcModelDir(model), "cl.exe"); // For the msvc-dmc wrapper
		env.vars["MSVC_AR"] = env.deps.vsDir.buildPath("VC", "bin", msvcModelDir(model), "lib.exe"); // For the msvc-lib wrapper
		env.vars["CL"] = "-D_USING_V110_SDK71_"; // Work around __userHeader macro redifinition VS bug
	}

	/// Disable the "<program> has stopped working"
	/// standard Windows dialog.
	version (Windows)
	static void disableCrashDialog()
	{
		enum : uint { SEM_FAILCRITICALERRORS = 1, SEM_NOGPFAULTERRORBOX = 2 }
		SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
	}

	version (OSX) protected
	{
		bool needWorkingCCChecked;
		void needWorkingCC()
		{
			if (!needWorkingCCChecked)
			{
				log("Checking for a working C compiler...");
				auto dir = buildPath(config.local.workDir, "temp", "cc-test");
				if (dir.exists) dir.rmdirRecurse();
				dir.mkdirRecurse();
				scope(success) rmdirRecurse(dir);

				write(dir.buildPath("test.c"), "int main() { return 0; }");
				auto status = spawnProcess(["cc", "test.c"], baseEnvironment.vars, std.process.Config.newEnv, dir).wait();
				enforce(status == 0, "Failed to compile a simple C program - no C compiler.");

				log("> OK");
				needWorkingCCChecked = true;
			}
		}

		bool haveEnumerateTLVChecked, haveEnumerateTLVValue;
		bool haveEnumerateTLV()
		{
			if (!haveEnumerateTLVChecked)
			{
				needWorkingCC();

				log("Checking for dyld_enumerate_tlv_storage...");
				auto dir = buildPath(config.local.workDir, "temp", "cc-tlv-test");
				if (dir.exists) dir.rmdirRecurse();
				dir.mkdirRecurse();
				scope(success) rmdirRecurse(dir);

				write(dir.buildPath("test.c"), "extern void dyld_enumerate_tlv_storage(void* handler); int main() { dyld_enumerate_tlv_storage(0); return 0; }");
				if (spawnProcess(["cc", "test.c"], baseEnvironment.vars, std.process.Config.newEnv, dir).wait() == 0)
				{
					log("> Present (probably 10.14 or older)");
					haveEnumerateTLVValue = true;
				}
				else
				{
					log("> Absent (probably 10.15 or newer)");
					haveEnumerateTLVValue = false;
				}
				haveEnumerateTLVChecked = true;
			}
			return haveEnumerateTLVValue;
		}
	}

	/// Create a build environment base.
	protected @property Environment baseEnvironment()
	{
		Environment env;

		// Build a new environment from scratch, to avoid tainting the build with the current environment.
		string[] newPaths;

		version (Windows)
		{
			import std.utf;
			import ae.sys.windows.imports;
			mixin(importWin32!q{winbase});
			mixin(importWin32!q{winnt});

			TCHAR[1024] buf;
			// Needed for DLLs
			auto winDir = buf[0..GetWindowsDirectory(buf.ptr, buf.length)].toUTF8();
			auto sysDir = buf[0..GetSystemDirectory (buf.ptr, buf.length)].toUTF8();
			newPaths ~= [sysDir, winDir];

			newPaths ~= gitInstaller.exePath("git").absolutePath().dirName; // For git-describe and such
		}
		else
		{
			// Needed for coreutils, make, gcc, git etc.
			newPaths = ["/bin", "/usr/bin", "/usr/local/bin"];

			version (linux)
			{
				// GCC wrappers
				ensureDirExists(binDir);
				newPaths = binDir ~ newPaths;
			}
		}

		env.vars["PATH"] = newPaths.join(pathSeparator);

		ensureDirExists(tmpDir);
		env.vars["TMPDIR"] = env.vars["TEMP"] = env.vars["TMP"] = tmpDir;

		version (Windows)
		{
			env.vars["SystemDrive"] = winDir.driveName;
			env.vars["SystemRoot"] = winDir;
		}

		ensureDirExists(homeDir);
		env.vars["HOME"] = homeDir;

		return env;
	}

	/// Apply user modifications onto an environment.
	/// Supports Windows-style %VAR% expansions.
	static string[string] applyEnv(in string[string] target, in string[string] source)
	{
		// The source of variable expansions is variables in the target environment,
		// if they exist, and the host environment otherwise, so e.g.
		// `PATH=C:\...;%PATH%` and `MAKE=%MAKE%` work as expected.
		auto oldEnv = std.process.environment.toAA();
		foreach (name, value; target)
			oldEnv[name] = value;

		string[string] result;
		foreach (name, value; target)
			result[name] = value;
		foreach (name, value; source)
		{
			string newValue = value;
			foreach (oldName, oldValue; oldEnv)
				newValue = newValue.replace("%" ~ oldName ~ "%", oldValue);
			result[name] = oldEnv[name] = newValue;
		}
		return result;
	}

	// ******************************** Cache ********************************

	/// Unbuildable versions are saved in the cache as a single empty file with this name.
	enum unbuildableMarker = "unbuildable";

	private DCache cacheEngine; /// Caches builds.

	DCache needCacheEngine()
	{
		if (!cacheEngine)
		{
			auto cacheEngine = createCache(cacheEngineName, cacheEngineDir(cacheEngineName), this);
			if (auto gitCache = cast(GitCache)cacheEngine)
				withInstaller({
					auto gitExecutable = gitInstaller.requireInstalled().getExecutable("git");
					gitCache.setGitExecutable(gitExecutable);
				});
			this.cacheEngine = cacheEngine;
		}
		return cacheEngine;
	} /// ditto

	protected void cp(string src, string dst)
	{
		needCacheEngine().cp(src, dst);
	}

	private string[] getComponentKeyOrder(string componentName)
	{
		auto submodule = getComponent(componentName).submodule;
		return submodule
			.git.query("log", "--pretty=format:%H", "--all", "--topo-order")
			.splitLines()
			.map!(commit => componentName ~ "-" ~ commit ~ "-")
			.array
		;
	}

	protected string componentNameFromKey(string key)
	{
		auto parts = key.split("-");
		return parts[0..$-2].join("-");
	}

	protected string[][] getKeyOrder(string key)
	{
		if (key !is null)
			return [getComponentKeyOrder(componentNameFromKey(key))];
		else
			return allComponents.map!(componentName => getComponentKeyOrder(componentName)).array;
	}

	/// Optimize entire cache.
	void optimizeCache()
	{
		needCacheEngine().optimize();
	}

	protected bool shouldPurge(string key)
	{
		auto files = cacheEngine.listFiles(key);
		if (files.canFind(unbuildableMarker))
			return true;

		if (componentNameFromKey(key) == "druntime")
		{
			if (!files.canFind("import/core/memory.d")
			 && !files.canFind("import/core/memory.di"))
				return true;
		}

		return false;
	}

	/// Delete cached "unbuildable" build results.
	void purgeUnbuildable()
	{
		needCacheEngine()
			.getEntries
			.filter!(key => shouldPurge(key))
			.each!((key)
			{
				log("Deleting: " ~ key);
				cacheEngine.remove(key);
			})
		;
	}

	/// Move cached files from one cache engine to another.
	void migrateCache(string sourceEngineName, string targetEngineName)
	{
		auto sourceEngine = createCache(sourceEngineName, cacheEngineDir(sourceEngineName), this);
		auto targetEngine = createCache(targetEngineName, cacheEngineDir(targetEngineName), this);
		auto tempDir = buildPath(config.local.workDir, "temp");
		if (tempDir.exists)
			tempDir.removeRecurse();
		log("Enumerating source entries...");
		auto sourceEntries = sourceEngine.getEntries();
		log("Enumerating target entries...");
		auto targetEntries = targetEngine.getEntries().sort();
		foreach (key; sourceEntries)
			if (!targetEntries.canFind(key))
			{
				log(key);
				sourceEngine.extract(key, tempDir, fn => true);
				targetEngine.add(key, tempDir);
				if (tempDir.exists)
					tempDir.removeRecurse();
			}
		targetEngine.optimize();
	}

	// **************************** Miscellaneous ****************************

	/// Gets the D merge log (newest first).
	struct LogEntry
	{
		string hash;      ///
		string[] message; ///
		SysTime time;     ///
	}

	/// ditto
	LogEntry[] getLog(string refName = "refs/remotes/origin/master")
	{
		auto history = getMetaRepo().git.getHistory();
		LogEntry[] logs;
		auto master = history.commits[history.refs[refName]];
		for (auto c = master; c; c = c.parents.length ? c.parents[0] : null)
		{
			auto time = SysTime(c.time.unixTimeToStdTime);
			logs ~= LogEntry(c.oid.toString(), c.message, time);
		}
		return logs;
	}

	// ***************************** Integration *****************************

	/// Override to add logging.
	void log(string line)
	{
	}

	/// Bootstrap description resolution.
	/// See DMD.Config.Bootstrap.spec.
	/// This is essentially a hack to allow the entire
	/// Config structure to be parsed from an .ini file.
	SubmoduleState parseSpec(string spec)
	{
		auto rev = getMetaRepo().getRef("refs/tags/" ~ spec);
		log("Resolved " ~ spec ~ " to " ~ rev);
		return begin(rev);
	}

	/// Override this method with one which returns a command,
	/// which will invoke the unmergeRebaseEdit function below,
	/// passing to it any additional parameters.
	/// Note: Currently unused. Was previously used
	/// for unmerging things using interactive rebase.
	deprecated abstract string getCallbackCommand();

	deprecated void callback(string[] args) { assert(false); }
}
