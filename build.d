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
import ae.sys.d.builder;

import cache;
import common;
import repo;

alias BuildConfig = DBuilder.Config.Build;
BuildConfig buildConfig;
bool inDelve;

version(Windows)
alias dmcDir = subDir!"dm";

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
static import ae.net.http.client;

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

				import std.stdio : File;
				import ae.net.http.client;
				import ae.net.asockets;
				import ae.sys.data;

				httpGet(url,
					(Data data) { std.file.write(target, data.contents); },
					(string error) { throw new Exception(error); }
				);

				socketManager.loop();
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

		TCHAR buf[1024];
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

DiggerBuilder builder;

void prepareBuilder()
{
	builder = new DiggerBuilder();
	builder.config.build = buildConfig;
	builder.config.local.repoDir = repoDir;
	builder.config.local.buildDir = buildDir;
	version(Windows)
	builder.config.local.dmcDir = dmcDir;
	builder.config.local.env = dEnv;
}

void prepareBuild()
{
	auto repo = Repository(repoDir);
	auto commit = repo.query("rev-parse", "HEAD");
	string currentCacheDir; // this build's cache location

	prepareEnv();
	prepareBuilder();

	if (currentDir.exists)
		currentDir.rmdirRecurse();

	if (config.cache)
	{
		auto buildID = "%s-%s".format(commit, builder.config.build);

		currentCacheDir = buildPath(cacheDir, buildID);
		if (currentCacheDir.exists)
		{
			log("Found in cache: " ~ currentCacheDir);
			currentCacheDir.dirLink(currentDir);
			enforce(!buildPath(currentDir, UNBUILDABLE_MARKER).exists, "This build was cached as unbuildable.");
			return;
		}
	}

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

class DiggerBuilder : DBuilder
{
	override void log(string s)
	{
		common.log(s);
	}
}

void build()
{
	clean();

	auto repo = Repository(repoDir);
	repo.run("submodule", "update");

	logProgress("Building...");
	mkdir(buildDir);

	builder.build();
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
