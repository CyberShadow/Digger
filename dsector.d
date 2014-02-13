module dsector;

import std.algorithm;
import std.array;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.string;

import ae.sys.file;

import common;
import repo;

enum EXIT_UNTESTABLE = 125;

int main(string[] args)
{
	if (opts.inBisect)
	{
		log("Invoked by git-bisect - performing bisect step.");
		auto result = doBisectStep();
		if (config.reverse && result != EXIT_UNTESTABLE)
			result = result ? 0 : 1;
		return result;
	}

	prepareRepo(true);
	prepareTools();

	auto repo = Repository(REPO);

	void test(bool good, string rev)
	{
		auto name = good ? "GOOD" : "BAD";
		log("Sanity-check, testing %s revision %s...".format(name, rev));
		repo.run("checkout", rev);
		auto result = doBisectStep();
		enforce(result != EXIT_UNTESTABLE,
			"%s revision %s is not testable"
			.format(name, rev));
		enforce(!result == good,
			"%s revision %s is not correct (exit status is %d)"
			.format(name, rev, result));
	}

	if (!opts.noVerify)
	{
		auto good = getRev!true();
		auto bad = getRev!false();

		enforce(good != bad, "Good and bad revisions are both " ~ bad);

		auto nGood = repo.query(["log", "--format=oneline", good]).splitLines().length;
		auto nBad  = repo.query(["log", "--format=oneline", bad ]).splitLines().length;
		if (config.reverse)
			enforce(nBad < nGood, "Bad commit is newer than good commit (and reverse search is enabled)");
		else
			enforce(nGood < nBad, "Good commit is newer than bad commit");

		test(true, good);
		test(false, bad);
	}

	auto startPoints = [getRev!false(), getRev!true()];
	if (config.reverse)
		startPoints.reverse;
	repo.run(["bisect", "start"] ~ startPoints);
	repo.run("bisect", "run",
		thisExePath,
		"--in-bisect",
		"--dir", getcwd(),
	);

	return 0;
}

int doBisectStep()
{
	if (!prepareBuild())
		return EXIT_UNTESTABLE;

	log("Running test command...");
	auto result = spawnShell(config.tester, dEnv, Config.newEnv).wait();
	log("Test command exited with status %s (%s).".format(result, result==0 ? "GOOD" : result==EXIT_UNTESTABLE ? "UNTESTABLE" : "BAD"));
	return result;
}

version(Windows)
enum DMC_DIR = "dm";

/// Obtains prerequisites necessary for building D.
void prepareTools()
{
	version(Windows)
	{
		void prepareDMC(string dmc)
		{
			void downloadFile(string url, string target)
			{
				log("Downloading " ~ url);
				import std.net.curl;
				download(url, target);
			}

			alias obtainUsing!downloadFile cachedDownload;
			cachedDownload("http://ftp.digitalmars.com/dmc.zip", "dmc.zip");
			cachedDownload("http://ftp.digitalmars.com/optlink.zip", "optlink.zip");

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

			safeUnzip("dmc.zip", "dmc");
			enforce(`dmc\dm\bin\dmc.exe`.exists);
			rename(`dmc\dm`, dmc);
			rmdir(`dmc`);
			remove("dmc.zip");

			safeUnzip("optlink.zip", `optlink`);
			rename(`optlink\link.exe`, dmc ~ `\bin\link.exe`);
			rmdir(`optlink`);
			remove("optlink.zip");
		}

		obtainUsing!(prepareDMC, q{dmc})(DMC_DIR);
	}
}

enum CURRENT_DIR = "current";
enum BUILD_DIR = "build";
enum CACHE_DIR = "cache";
enum UNBUILDABLE_MARKER = "unbuildable";

string[string] dEnv;

bool prepareBuild()
{
	string cacheDir;

	if (CURRENT_DIR.exists)
		CURRENT_DIR.rmdirRecurse();

	bool doBuild = true;

	if (config.cache)
	{
		auto repo = Repository(REPO);
		auto commit = repo.query("rev-parse", "HEAD");
		auto buildID = commit;
		cacheDir = CACHE_DIR.buildPath(buildID);
		if (cacheDir.exists)
		{
			cacheDir.dirLink(CURRENT_DIR);
			doBuild = false;
		}
	}

	if (doBuild)
	{
		{
			auto oldPaths = environment["PATH"].split(pathSeparator);

			// Build a new environment from scratch, to avoid tainting the build with the current environment.
			string[] newPaths;
			dEnv = null;

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
			newPaths ~= buildPath(BUILD_DIR, "bin").absolutePath();   // For Phobos/Druntime/Tools
			newPaths ~= buildPath(CURRENT_DIR, "bin").absolutePath(); // For other D programs

			// Add the DM tools
			version (Windows)
			{
				auto dmc = buildPath(DMC_DIR, `bin`).absolutePath();
				dEnv["DMC"] = dmc;
				newPaths ~= dmc;
			}

			dEnv["PATH"] = newPaths.join(pathSeparator);

			version(Windows)
			{
				dEnv["TEMP"] = dEnv["TMP"] = tmpDir;
				dEnv["SystemRoot"] = winDir;
			}
		}

		try
			build();
		catch (Exception e)
		{
			if (BUILD_DIR.exists)
			{
				log("Build failed: " ~ e.msg);
				buildPath(BUILD_DIR, UNBUILDABLE_MARKER).touch();
			}
			else // Failed even before we started building
				throw e;
		}
	}

	if (config.cache)
	{
		BUILD_DIR.rename(cacheDir);
		cacheDir.dirLink(CURRENT_DIR);
	}
	else
		rename(BUILD_DIR, CURRENT_DIR);

	return !buildPath(CURRENT_DIR, UNBUILDABLE_MARKER).exists;
}

void build()
{
	clean();

	auto repo = Repository(REPO);
	repo.run("submodule", "update");

	mkdir(BUILD_DIR);
	buildDMD();
	buildDruntime();
	buildPhobos();
	buildTools();
}

void clean()
{
	logProgress("CLEANUP");
	if (BUILD_DIR.exists)
		BUILD_DIR.rmdirRecurse();
	enforce(!BUILD_DIR.exists);

	auto repo = Repository(REPO);
	repo.run("submodule", "foreach", "git", "reset", "--hard");
	repo.run("submodule", "foreach", "git", "clean", "--force", "-x", "-d");
}

void install(string src, string dst)
{
	ensurePathExists(dst);
	if (dst.exists && dst.isDir)
	{
		foreach (de; src.dirEntries(SpanMode.shallow))
			install(de.name, dst.buildPath(de.name.baseName));
	}
	else
	{
		log(src ~ " -> " ~ dst);
		rename(src, dst);
	}
}

@property string model() { return config.model; }
@property string modelSuffix() { return config.model == config.init.model ? "" : config.model; }
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
	logProgress("BUILDING DMD");

	{
		auto owd = pushd(buildPath(REPO, "dmd", "src"));
		run(["make", "-f", makeFileName, "MODEL=" ~ model], dEnv);
	}

	install(
		buildPath(REPO, "dmd", "src", "dmd" ~ binExt),
		buildPath(BUILD_DIR, "bin", "dmd" ~ binExt),
	);

	version (Windows)
	{
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
		buildPath(BUILD_DIR, "bin", "sc.ini").write(ini);
	}
	else
	{
		auto ini = q"EOS
[Environment]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib"
EOS";
		buildPath(BUILD_DIR, "bin", "dmd.conf").write(ini);
	}

	log("DMD OK!");
}

void buildDruntime()
{
	{
		auto owd = pushd(buildPath(REPO, "druntime"));

		mkdir("import");
		mkdir("lib");

		version (Windows)
		{
			auto lib = buildPath("lib", "druntime%s.lib".format(modelSuffix));
			auto obj = buildPath("lib", "gcstub%s.obj"  .format(modelSuffix));
			run(["make", "-f", makeFileNameModel, "MODEL=" ~ model, lib, obj, "import", "copydir", "copy"], dEnv);
			enforce(lib.exists);
			enforce(obj.exists);
		}
		else
		{
			run(["make", "-f", makeFileNameModel, "MODEL=" ~ model], dEnv);
		}
	}

	install(
		buildPath(REPO, "druntime", "import"),
		buildPath(BUILD_DIR, "import"),
	);


	log("Druntime OK!");
}

void buildPhobos()
{
	string[] targets;

	{
		auto owd = pushd(buildPath(REPO, "phobos"));
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

	foreach (f; ["std", "etc", "crc32.d"])
		if (buildPath(REPO, "phobos", f).exists)
			install(
				buildPath(REPO, "phobos", f),
				buildPath(BUILD_DIR, "import", f),
			);
	foreach (lib; targets)
		install(
			buildPath(REPO, "phobos", lib),
			buildPath(BUILD_DIR, "lib", lib.baseName()),
		);

	log("Phobos OK!");
}

void buildTools()
{
	// Just build rdmd
	{
		auto owd = pushd(buildPath(REPO, "tools"));
		run(["dmd", "-m" ~ model, "rdmd"], dEnv);
	}
	install(
		buildPath(REPO, "tools", "rdmd" ~ binExt),
		buildPath(BUILD_DIR, "bin", "rdmd" ~ binExt),
	);

	log("Tools OK!");
}
