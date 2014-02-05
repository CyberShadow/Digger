module build;

import std.algorithm;
import std.array;
import std.datetime;
import std.exception;
import std.file;
import std.path;
import std.process : environment;
import std.string;

import ae.sys.file;

import cache;
import common;
import repo;

struct BuildConfig
{
	string model = "32";
	bool debugDMD = false;
}
BuildConfig buildConfig;
bool inDelve;

version(Windows)
alias dmcDir = subDir!"dm";

/// Obtains prerequisites necessary for building D.
void prepareTools()
{
	version(Windows)
	{
		void prepareDMC(string dmc)
		{
			auto workDir = config.workDir;

			void downloadFile(string url, string target)
			{
				log("Downloading " ~ url);
				import std.net.curl;
				download(url, target);
			}

			alias obtainUsing!downloadFile cachedDownload;
			cachedDownload("http://ftp.digitalmars.com/dmc.zip", buildPath(workDir, "dmc.zip"));
			cachedDownload("http://ftp.digitalmars.com/optlink.zip", buildPath(workDir, "optlink.zip"));

			void unzip(string zip, string target)
			{
				log("Unzipping " ~ zip);
				import std.zip;
				auto archive = new ZipArchive(zip.read);
				foreach (name, entry; archive.directory)
				{
					auto path = buildPath(target, name);
					ensurePathExists(path);
					if (name.endsWith(`/`))
						path.mkdirRecurse();
					else
						std.file.write(path, archive.expand(entry));
				}
			}

			alias safeUpdate!unzip safeUnzip;

			safeUnzip(buildPath(workDir, "dmc.zip"), buildPath(workDir, "dmc"));
			enforce(buildPath(workDir, "dmc", "dm", "bin", "dmc.exe").exists);
			rename(buildPath(workDir, "dmc", "dm"), dmc);
			rmdir(buildPath(workDir, "dmc"));
			remove(buildPath(workDir, "dmc.zip"));

			safeUnzip(buildPath(workDir, "optlink.zip"), buildPath(workDir, "optlink"));
			rename(buildPath(workDir, "optlink", "link.exe"), buildPath(dmc, "bin", "link.exe"));
			rmdir(buildPath(workDir, "optlink"));
			remove(buildPath(workDir, "optlink.zip"));
		}

		obtainUsing!(prepareDMC, q{dmc})(dmcDir);
	}
}

alias currentDir = subDir!"current";     /// Final build directory
alias buildDir   = subDir!"build";       /// Temporary build directory
enum UNBUILDABLE_MARKER = "unbuildable";

string[string] dEnv;

void prepareEnv()
{
	if (dEnv)
		return;

	auto oldPaths = environment["PATH"].split(pathSeparator);

	// Build a new environment from scratch, to avoid tainting the build with the current environment.
	string[] newPaths;

	version(Windows)
	{
		import std.utf;
		import win32.winbase;
		import win32.winnt;

		WCHAR buf[1024];
		auto winDir = buf[0..GetWindowsDirectory(buf.ptr, buf.length)].toUTF8();
		auto sysDir = buf[0..GetSystemDirectory (buf.ptr, buf.length)].toUTF8();
		auto tmpDir = buf[0..GetTempPath(buf.length, buf.ptr)].toUTF8()[0..$-1];
		newPaths ~= [sysDir, winDir];
	}
	else
		newPaths = ["/bin", "/usr/bin"];

	// Add the DMD we built
	newPaths ~= buildPath(buildDir, "bin").absolutePath();   // For Phobos/Druntime/Tools
	newPaths ~= buildPath(currentDir, "bin").absolutePath(); // For other D programs

	// Add the DM tools
	version (Windows)
	{
		auto dmc = buildPath(dmcDir, `bin`).absolutePath();
		dEnv["DMC"] = dmc;
		newPaths ~= dmc;
	}

	dEnv["PATH"] = newPaths.join(pathSeparator);

	version(Windows)
	{
		dEnv["TEMP"] = dEnv["TMP"] = tmpDir;
		dEnv["SystemRoot"] = winDir;
	}

	applyEnv(config.environment);
}

void applyEnv(in string[string] env)
{
	auto oldEnv = environment.toAA();
	foreach (name, value; dEnv)
		oldEnv[name] = value;
	foreach (name, value; env)
	{
		string newValue = value;
		foreach (oldName, oldValue; oldEnv)
			newValue = newValue.replace("%" ~ oldName ~ "%", oldValue);
		dEnv[name] = oldEnv[name] = newValue;
	}
}

void prepareBuild()
{
	auto repo = Repository(repoDir);
	auto commit = repo.query("rev-parse", "HEAD");
	string currentCacheDir; // this build's cache location

	if (currentDir.exists)
		currentDir.rmdirRecurse();

	if (config.cache)
	{
		auto buildID = "%s-%s".format(commit, model);
		currentCacheDir = buildPath(cacheDir, buildID);
		if (currentCacheDir.exists)
		{
			log("Found in cache: " ~ currentCacheDir);
			currentCacheDir.dirLink(currentDir);
			enforce(!buildPath(currentDir, UNBUILDABLE_MARKER).exists, "This build was cached as unbuildable.");
			return;
		}
	}

	prepareEnv();

	scope (exit)
	{
		if (buildDir.exists)
		{
			if (currentCacheDir)
			{
				ensurePathExists(currentCacheDir);
				buildDir.rename(currentCacheDir);
				currentCacheDir.dirLink(currentDir);
				optimizeRevision(commit);
			}
			else
				rename(buildDir, currentDir);
		}
	}

	scope (failure)
	{
		if (buildDir.exists)
		{
			// An incomplete build is useless, nuke the directory
			// and create a new one just for the UNBUILDABLE_MARKER.
			rmdirRecurse(buildDir);
			mkdir(buildDir);
			buildPath(buildDir, UNBUILDABLE_MARKER).touch();

			// Don't cache failed build results during delve
			if (inDelve)
				currentCacheDir = null;
		}
	}

	build();
}

void build()
{
	clean();

	auto repo = Repository(repoDir);
	repo.run("submodule", "update");

	logProgress("Building...");
	mkdir(buildDir);
	buildDMD();
	buildPhobosIncludes();
	buildDruntime();
	buildPhobos();
	buildTools();
}

void clean()
{
	log("Cleaning up...");
	if (buildDir.exists)
		buildDir.rmdirRecurse();
	enforce(!buildDir.exists);

	auto repo = Repository(repoDir);
	repo.run("submodule", "foreach", "git", "reset", "--hard");
	repo.run("submodule", "foreach", "git", "clean", "--force", "-x", "-d", "--quiet");
}

void install(string src, string dst)
{
	ensurePathExists(dst);
	if (src.isDir)
	{
		dst.mkdirRecurse();
		foreach (de; src.dirEntries(SpanMode.shallow))
			install(de.name, dst.buildPath(de.name.baseName));
	}
	else
	{
		debug log(src ~ " -> " ~ dst);
		hardLink(src, dst);
	}
}

@property string model() { return buildConfig.model; }
@property string modelSuffix() { return buildConfig.model == buildConfig.init.model ? "" : buildConfig.model; }
version (Windows)
{
	enum string makeFileName = "win32.mak";
	@property string makeFileNameModel() { return "win"~model~".mak"; }
	enum string binExt = ".exe";
}
else
{
	enum string makeFileName = "posix.mak";
	enum string makeFileNameModel = "posix.mak";
	enum string binExt = "";
}

void buildDMD()
{
	{
		auto owd = pushd(buildPath(repoDir, "dmd", "src"));
		string[] targets = buildConfig.debugDMD ? [] : ["dmd"];
		run(["make", "-f", makeFileName, "MODEL=" ~ model] ~ targets, dEnv);
	}

	install(
		buildPath(repoDir, "dmd", "src", "dmd" ~ binExt),
		buildPath(buildDir, "bin", "dmd" ~ binExt),
	);

	version (Windows)
	{
		// TODO: either properly detect where VS and the SDK are installed,
		// or obtain and create a portable install with only the necessary components,
		// as done here: https://github.com/CyberShadow/FarCI
		auto ini = q"EOS
[Environment]
LIB="%@P%\..\lib"
DFLAGS="-I%@P%\..\import"
LINKCMD=%DMC%\link.exe
[Environment64]
LIB="%@P%\..\lib"
DFLAGS=%DFLAGS% -L/OPT:NOICF
VCINSTALLDIR=\Program Files (x86)\Microsoft Visual Studio 10.0\VC\
PATH=%PATH%;%VCINSTALLDIR%\bin\amd64
WindowsSdkDir=\Program Files (x86)\Microsoft SDKs\Windows\v7.0A
LINKCMD=%VCINSTALLDIR%\bin\amd64\link.exe
LIB=%LIB%;"%VCINSTALLDIR%\lib\amd64"
LIB=%LIB%;"%WindowsSdkDir%\Lib\winv6.3\um\x64"
LIB=%LIB%;"%WindowsSdkDir%\Lib\win8\um\x64"
LIB=%LIB%;"%WindowsSdkDir%\Lib\x64"
EOS";
		buildPath(buildDir, "bin", "sc.ini").write(ini);
	}
	else
	{
		auto ini = q"EOS
[Environment]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib"
EOS";
		buildPath(buildDir, "bin", "dmd.conf").write(ini);
	}

	log("DMD OK!");
}

void buildDruntime()
{
	{
		auto owd = pushd(buildPath(repoDir, "druntime"));

		mkdirRecurse("import");
		mkdirRecurse("lib");

		setTimes(buildPath("src", "rt", "minit.obj"), Clock.currTime(), Clock.currTime());

		run(["make", "-f", makeFileNameModel, "MODEL=" ~ model], dEnv);
	}

	install(
		buildPath(repoDir, "druntime", "import"),
		buildPath(buildDir, "import"),
	);


	log("Druntime OK!");
}

void buildPhobosIncludes()
{
	// In older versions of D, Druntime depended on Phobos modules.
	foreach (f; ["std", "etc", "crc32.d"])
		if (buildPath(repoDir, "phobos", f).exists)
			install(
				buildPath(repoDir, "phobos", f),
				buildPath(buildDir, "import", f),
			);
}

void buildPhobos()
{
	string[] targets;

	{
		auto owd = pushd(buildPath(repoDir, "phobos"));
		version (Windows)
		{
			auto lib = "phobos%s.lib".format(modelSuffix);
			run(["make", "-f", makeFileNameModel, "MODEL=" ~ model, lib], dEnv);
			enforce(lib.exists);
			targets = [lib];
		}
		else
		{
			run(["make", "-f", makeFileNameModel, "MODEL=" ~ model], dEnv);
			targets = "generated".dirEntries(SpanMode.depth).filter!(de => de.name.endsWith(".a")).map!(de => de.name).array();
		}
	}

	foreach (lib; targets)
		install(
			buildPath(repoDir, "phobos", lib),
			buildPath(buildDir, "lib", lib.baseName()),
		);

	log("Phobos OK!");
}

void buildTools()
{
	// Just build rdmd
	{
		auto owd = pushd(buildPath(repoDir, "tools"));
		run(["dmd", "-m" ~ model, "rdmd"], dEnv);
	}
	install(
		buildPath(repoDir, "tools", "rdmd" ~ binExt),
		buildPath(buildDir, "bin", "rdmd" ~ binExt),
	);

	log("Tools OK!");
}
