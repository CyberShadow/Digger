module install;

import std.algorithm;
import std.array;
import std.exception;
import std.file;
import std.path;
import std.string;

import ae.sys.file;
import ae.utils.array;
import ae.utils.json;

import common;
import config;
import custom;

version (Windows)
{
	enum string binExt = ".exe";
	enum string dmdConfigName = "sc.ini";
}
else
{
	enum string binExt = "";
	enum string dmdConfigName = "dmd.conf";
}

version (Windows)
	enum string platformDir = "windows";
else
version (linux)
	enum string platformDir = "linux";
else
version (OSX)
	enum string platformDir = "osx";
else
version (FreeBSD)
	enum string platformDir = "freebsd";
else
	enum string platformDir = null;

string[] findDMD()
{
	string[] result;
	foreach (pathEntry; environment.get("PATH", null).split(pathSeparator))
	{
		auto dmd = pathEntry.buildPath("dmd" ~ binExt);
		if (dmd.exists)
			result ~= dmd;
	}
	return result;
}

string selectInstallPath(string location)
{
    string[] candidates;
    if (location)
	{
		auto dmd = location.absolutePath();
		@property bool ok() { return dmd.exists && dmd.isFile; }

		if (!ok)
		{
			string newDir;

			bool dirOK(string dir)
			{
				newDir = dmd.buildPath(dir);
				return newDir.exists && newDir.isDir;
			}

			bool tryDir(string dir)
			{
				if (dirOK(dir))
				{
					dmd = newDir;
					return true;
				}
				return false;
			}

			tryDir("dmd2");

			static if (platformDir)
				tryDir(platformDir);

			enforce(!dirOK("bin32") || !dirOK("bin64"),
				"Ambiguous model in path - please specify full path to DMD binary");
			tryDir("bin") || tryDir("bin32") || tryDir("bin64");

			dmd = dmd.buildPath("dmd" ~ binExt);
			enforce(ok, "DMD installation not detected at " ~ location);
		}

		candidates = [dmd];
	}
	else
	{
		candidates = findDMD();
		enforce(candidates.length, "DMD not found in PATH - "
			"add DMD to PATH or specify install location explicitly");
	}

	foreach (candidate; candidates)
	{
		if (candidate.buildNormalizedPath.startsWith(workDir.buildNormalizedPath))
		{
			log("Skipping DMD installation under Digger workDir: " ~ candidate);
			continue;
		}

		log("Found DMD executable: " ~ candidate);
		return candidate;
	}

	throw new Exception("No suitable DMD installation found.");
}

string findConfig(string dmdPath)
{
	string configPath;

	bool pathOK(string path)
	{
		configPath = path.buildPath(dmdConfigName);
		return configPath.exists;
	}

	if (pathOK(dmdPath.dirName))
		return configPath;

	auto home = environment.get("HOME", null);
	if (home && pathOK(home))
		return configPath;

	version (Posix)
		if (pathOK("/etc/"))
			return configPath;

	throw new Exception("Can't find DMD configuration file %s "
		"corresponding to DMD located at %s".format(dmdConfigName, dmdPath));
}

struct ComponentPaths
{
	string binPath;
	string libPath;
	string phobosPath;
	string druntimePath;
}

ComponentPaths parseConfig(string dmdPath, BuildInfo buildInfo)
{
	auto configPath = findConfig(dmdPath);
	log("Found DMD configuration: " ~ configPath);

	string[string] vars = environment.toAA();
	bool parsing = false;
	foreach (line; configPath.readText().splitLines())
	{
		if (line.startsWith("[") && line.endsWith("]"))
		{
			auto sectionName = line[1..$-1];
			parsing = sectionName == "Environment"
			       || sectionName == "Environment" ~ buildInfo.config.model;
		}
		else
		if (parsing && line.canFind("="))
		{
			string name, value;
			list(name, null, value) = line.findSplit("=");
			auto parts = value.split("%");
			for (size_t n = 1; n < parts.length; n+=2)
				if (!parts[n].length)
					parts[n] = "%";
				else
				if (parts[n] == "@P")
					parts[n] = configPath.dirName();
				else
					parts[n] = vars.get(parts[n], parts[n]);
			value = parts.join();
			vars[name] = value;
		}
	}

	string[] parseParameters(string s, char escape = '\\', char separator = ' ')
	{
		string[] result;
		while (s.length)
			if (s[0] == separator)
				s = s[1..$];
			else
			{
				string p;
				if (s[0] == '"')
				{
					s = s[1..$];
					bool escaping, end;
					while (s.length && !end)
					{
						auto c = s[0];
						s = s[1..$];
						if (!escaping && c == '"')
							end = true;
						else
						if (!escaping && c == escape)
							escaping = true;
						else
						{
							if (escaping && c != escape)
								p ~= escape;
							p ~= c;
							escaping = false;
						}
					}
				}
				else
					list(p, null, s) = s.findSplit([separator]);
				result ~= p;
			}
		return result;
	}

	string[] dflags = parseParameters(vars.get("DFLAGS", null));
	string[] importPaths = dflags
		.filter!(s => s.startsWith("-I"))
		.map!(s => s[2..$].split(";"))
		.join();

	version (Windows)
		string[] libPaths = parseParameters(vars.get("LIB", null), 0, ';');
	else
		string[] libPaths = dflags
			.filter!(s => s.startsWith("-L-L"))
			.map!(s => s[4..$])
			.array();

	string findPath(string[] paths, string name, string testFile)
	{
		auto results = paths.find!(path => path.buildPath(testFile).exists);
		enforce(!results.empty, "Can't find %s (%s). Looked in: %s".format(name, testFile, paths));
		auto result = results.front.buildNormalizedPath();
		log("Found %s (%s): %s".format(name, testFile, result));
		return result;
	}

	ComponentPaths result;
	result.binPath = dmdPath.dirName();
	result.libPath = findPath(libPaths, "Phobos static library", getLibName(buildInfo));
	result.phobosPath = findPath(importPaths, "Phobos source code", "std/stdio.d");
	result.druntimePath = findPath(importPaths, "Druntime import files", "object.di");
	return result;
}

string getLibName(BuildInfo buildInfo)
{
	version (Windows)
		return "phobos%s.lib".format(buildInfo.config.model == "32" ? "" : buildInfo.config.model);
	else
		return "libphobos2.a";
}

struct InstalledObject
{
	/// File name in backup directory
	string name;

	/// Original location.
	/// Path is relative to uninstall.json's directory.
	string path;

	/// MD5 sum of the NEW object's contents
	/// (not the one in the install directory).
	/// For directories, this is the MD5 sum
	/// of all files sorted by name (see mdDir).
	string hash;
}

struct UninstallData
{
	InstalledObject[] objects;
}

void install(bool yes, bool dryRun, string location = null)
{
	assert(!yes || !dryRun, "Mutually exclusive options");
	auto dmdPath = selectInstallPath(location);

	auto buildInfoPath = resultDir.buildPath(buildInfoFileName);
	enforce(buildInfoPath.exists,
		buildInfoPath ~ " not found - please purge cache and rebuild");
	auto buildInfo = buildInfoPath.readText().jsonParse!BuildInfo();

	auto componentPaths = parseConfig(dmdPath, buildInfo);

	auto verb = dryRun ? "Would" : "Will";
	log("%s install:".format(verb));
	log(" - Binaries to:           " ~ componentPaths.binPath);
	log(" - Libraries to:          " ~ componentPaths.libPath);
	log(" - Phobos source code to: " ~ componentPaths.phobosPath);
	log(" - Druntime includes to:  " ~ componentPaths.druntimePath);

	auto uninstallPath = buildPath(componentPaths.binPath, ".digger-install");
	auto uninstallFileName = buildPath(uninstallPath, "uninstall.json");
	if (uninstallFileName.exists)
		log("Uninstallation data exists - %s uninstall first.".format(verb));

	auto libName = getLibName(buildInfo);

	static struct Item
	{
		string name, srcPath, dstPath;
	}

	Item[] items =
	[
		Item("dmd"  ~ binExt, buildPath(resultDir, "bin", "dmd"  ~ binExt), dmdPath),
		Item("rdmd" ~ binExt, buildPath(resultDir, "bin", "rdmd" ~ binExt), buildPath(componentPaths.binPath, "rdmd" ~ binExt)),
		Item(libName        , buildPath(resultDir, "lib", libName)        , buildPath(componentPaths.libPath, libName)),
		Item("object.di"    , buildPath(resultDir, "import", "object.di") , buildPath(componentPaths.druntimePath, "object.di")),
		Item("core"         , buildPath(resultDir, "import", "core")      , buildPath(componentPaths.druntimePath, "core")),
		Item("std"          , buildPath(resultDir, "import", "std")       , buildPath(componentPaths.phobosPath, "std")),
		Item("etc"          , buildPath(resultDir, "import", "etc")       , buildPath(componentPaths.phobosPath, "etc")),
	];

	log("Actions to run:");
	foreach (item; items)
	{
		enforce(item.srcPath.exists, "Can't find source for component %s: %s".format(item.name, item.srcPath));
		enforce(item.dstPath.exists, "Can't find target for component %s: %s".format(item.name, item.dstPath));
		log(" - Install component %s from %s to %s".format(item.name, item.srcPath, item.dstPath));
	}

	if (dryRun)
	{
		log("Dry run, exiting.");
		return;
	}

	if (yes)
		log("Proceeding with installation.");
	else
	{
		import std.stdio : stdin, stderr;

		string result;
		do
		{
			stderr.write("Continue? [Y/n] "); stderr.flush();
			result = stdin.readln().chomp().toLower();
		} while (result != "y" && result != "n" && result != "");
		if (result == "n")
			return;
	}

	if (uninstallFileName.exists)
	{
		log("First uninstalling previous installed version, using data in " ~ uninstallPath);
		scope(failure) log("Uninstallation error. You may delete " ~ uninstallPath ~ " to remove installation information.");
		uninstall(location);
	}

	assert(!uninstallFileName.exists);
	enforce(!uninstallPath.exists, "Uninstallation directory exists without uninstall.json: " ~ uninstallPath);

	log("Preparing object list...");

	UninstallData uninstallData;
	foreach (item; items)
	{
		log(" - " ~ item.name);
		uninstallData.objects ~= InstalledObject(item.name, item.dstPath.relativePath(uninstallPath), mdObject(item.srcPath));
	}

	log("Saving uninstall information...");

	mkdir(uninstallPath);
	std.file.write(uninstallFileName, toJson(uninstallData));

	log("Backing up old files...");

	foreach (item; items)
	{
		log(" - " ~ item.name);
		auto backupPath = buildPath(uninstallPath, item.name);
		rename(item.dstPath, backupPath);
	}

	log("Installing new files...");

	foreach (item; items)
	{
		log(" - " ~ item.name);
		atomic!cpObject(item.srcPath, item.dstPath);
	}

	log("Install OK.");
	log("You can undo this action by running `digger uninstall`.");
}

void uninstall(string location = null)
{
	auto dmdPath = selectInstallPath(location);
	auto binPath = dmdPath.dirName();
	auto uninstallPath = buildPath(binPath, ".digger-install");
	auto uninstallFileName = buildPath(uninstallPath, "uninstall.json");
	enforce(uninstallFileName.exists, "Can't find uninstallation data: " ~ uninstallFileName);
	auto uninstallData = uninstallFileName.readText.jsonParse!UninstallData;

	log("Verifying files to be uninstalled...");

	foreach (obj; uninstallData.objects)
	{
		auto path = buildPath(uninstallPath, obj.path);
		enforce(path.exists, "Can't find item to uninstall: " ~ path);
		auto hash = mdObject(path);
		enforce(hash == obj.hash, "Object changed since it was installed: " ~ path ~ "\nPlease uninstall manually.");
	}

	log("Verify OK, uninstalling...");

	foreach (obj; uninstallData.objects)
	{
		auto src = buildPath(uninstallPath, obj.name);
		auto dst = buildPath(uninstallPath, obj.path);
		log(" > Removing " ~ dst);
		rmObject(dst);
		log("   Moving " ~ src ~ " to " ~ dst);
		rename(src, dst);
	}

	remove(uninstallFileName);

	rmdir(uninstallPath); // should be empty now

	log("Uninstall OK.");
}

string mdDir(string dir)
{
	import std.stdio : File;
	import std.digest.md;

	auto dataChunks = dir
		.dirEntries(SpanMode.breadth)
		.filter!(de => de.isFile)
		.map!(de => de.name.replace(`\`, `/`))
		.array()
		.sort()
		.map!(name => File(name, "rb").byChunk(4096))
		.joiner();

	MD5 digest;
	digest.start();
	foreach (chunk; dataChunks)
		digest.put(chunk);
	auto result = digest.finish();
	// https://issues.dlang.org/show_bug.cgi?id=9279
	auto str = result.toHexString();
	return str[].idup;
}

void rmObject(string path) { path.isDir ? path.rmdirRecurse() : path.remove(); }

void cpObject(string src, string dst)
{
	if (src.isDir)
	{
		mkdir(dst);
		foreach (de; src.dirEntries(SpanMode.shallow))
			cpObject(de.name, buildPath(dst, de.baseName));
	}
	else
		copy(src, dst);
}

string mdObject(string path)
{
	import std.digest.digest;

	if (path.isDir)
		return path.mdDir();
	else
	{
		auto result = path.mdFile();
		// https://issues.dlang.org/show_bug.cgi?id=9279
		auto str = result.toHexString();
		return str[].idup;
	}
}
