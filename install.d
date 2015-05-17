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

version (Posix)
{
	import core.sys.posix.unistd;
	import std.conv : octal;
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
			       || sectionName == "Environment" ~ buildInfo.config.components.common.model;
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

	string findPath(string[] paths, string name, string[] testFiles)
	{
		auto results = paths.find!(path => testFiles.any!(testFile => path.buildPath(testFile).exists));
		enforce(!results.empty, "Can't find %s (%-(%s or %)). Looked in: %s".format(name, testFiles, paths));
		auto result = results.front.buildNormalizedPath();
		auto testFile = testFiles.find!(testFile => result.buildPath(testFile).exists).front;
		log("Found %s (%s): %s".format(name, testFile, result));
		return result;
	}

	ComponentPaths result;
	result.binPath = dmdPath.dirName();
	result.libPath = findPath(libPaths, "Phobos static library", [getLibFileName(buildInfo)]);
	result.phobosPath = findPath(importPaths, "Phobos source code", ["std/stdio.d"]);
	result.druntimePath = findPath(importPaths, "Druntime import files", ["object.d", "object.di"]);
	return result;
}

string getLibFileName(BuildInfo buildInfo)
{
	version (Windows)
	{
		auto model = buildInfo.config.components.common.model;
		return "phobos%s.lib".format(model == "32" ? "" : model);
	}
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
	InstalledObject*[] objects;
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
	bool updating = uninstallFileName.exists;
	if (updating)
	{
		log("Found previous installation data in " ~ uninstallPath);
		log("%s update existing installation.".format(verb));
	}
	else
	{
		log("This %s be a new Digger installation.".format(verb.toLower));
		log("Backups and uninstall data %s be saved in %s".format(verb.toLower, uninstallPath));
	}

	auto libFileName = getLibFileName(buildInfo);
	auto libName = libFileName.stripExtension ~ "-" ~ buildInfo.config.components.common.model ~ libFileName.extension;

	static struct Item
	{
		string name, srcPath, dstPath;
	}

	Item[] items =
	[
		Item("dmd"  ~ binExt, buildPath(resultDir, "bin", "dmd"  ~ binExt), dmdPath),
		Item("rdmd" ~ binExt, buildPath(resultDir, "bin", "rdmd" ~ binExt), buildPath(componentPaths.binPath, "rdmd" ~ binExt)),
		Item(libName        , buildPath(resultDir, "lib", libFileName)    , buildPath(componentPaths.libPath, libFileName)),
		Item("object.di"    , buildPath(resultDir, "import", "object.{d,di}").globFind,
		                                                                    buildPath(componentPaths.druntimePath, "object.{d,di}").globFind),
		Item("core"         , buildPath(resultDir, "import", "core")      , buildPath(componentPaths.druntimePath, "core")),
		Item("std"          , buildPath(resultDir, "import", "std")       , buildPath(componentPaths.phobosPath, "std")),
		Item("etc"          , buildPath(resultDir, "import", "etc")       , buildPath(componentPaths.phobosPath, "etc")),
	];

	InstalledObject*[string] existingComponents;
	bool[string] updateNeeded;

	UninstallData uninstallData;

	if (updating)
	{
		uninstallData = uninstallFileName.readText.jsonParse!UninstallData;
		foreach (obj; uninstallData.objects)
			existingComponents[obj.name] = obj;
	}

	log("Preparing object list...");

	foreach (item; items)
	{
		log(" - " ~ item.name);

		auto obj = new InstalledObject(item.name, item.dstPath.relativePath(uninstallPath), mdObject(item.srcPath));
		auto pexistingComponent = item.name in existingComponents;
		if (pexistingComponent)
		{
			auto existingComponent = *pexistingComponent;

			enforce(existingComponent.path == obj.path,
				"Updated component has a different path (%s vs %s), aborting."
				.format(existingComponents[item.name].path, obj.path));

			verifyObject(existingComponent, uninstallPath, "update");

			updateNeeded[item.name] = existingComponent.hash != obj.hash;
			existingComponent.hash = obj.hash;
		}
		else
			uninstallData.objects ~= obj;
	}

	log("Testing write access and filesystem boundaries:");

	string[] dirs = items.map!(item => item.dstPath.dirName).array.sort().uniq().array;
	foreach (dir; dirs)
	{
		log(" - %s".format(dir));
		auto testPathA = dir.buildPath(".digger-test");
		auto testPathB = componentPaths.binPath.buildPath(".digger-test2");

		std.file.write(testPathA, "test");
		{
			scope(failure) remove(testPathA);
			rename(testPathA, testPathB);
		}
		remove(testPathB);
	}

	version (Posix)
	{
		int owner = dmdPath.getOwner();
		int group = dmdPath.getGroup();
		int mode = items.front.dstPath.getAttributes() & octal!666;
		log("UID=%d GID=%d Mode=%03o".format(owner, group, mode));
	}

	log("Things to do:");

	foreach (item; items)
	{
		enforce(item.srcPath.exists, "Can't find source for component %s: %s".format(item.name, item.srcPath));
		enforce(item.dstPath.exists, "Can't find target for component %s: %s".format(item.name, item.dstPath));

		string action;
		if (updating && item.name in existingComponents)
			action = updateNeeded[item.name] ? "Update" : "Skip unchanged";
		else
			action = "Install";
		log(" - %s component %s from %s to %s".format(action, item.name, item.srcPath, item.dstPath));
	}

	log("You %s be able to undo this action by running `digger uninstall`.".format(verb.toLower));

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
			stderr.write("Proceed with installation? [Y/n] "); stderr.flush();
			result = stdin.readln().chomp().toLower();
		} while (result != "y" && result != "n" && result != "");
		if (result == "n")
			return;
	}

	enforce(updating || !uninstallPath.exists, "Uninstallation directory exists without uninstall.json: " ~ uninstallPath);

	log("Saving uninstall information...");

	if (!updating)
		mkdir(uninstallPath);
	std.file.write(uninstallFileName, toJson(uninstallData));

	log("Backing up original files...");

	foreach (item; items)
		if (item.name !in existingComponents)
		{
			log(" - " ~ item.name);
			auto backupPath = buildPath(uninstallPath, item.name);
			rename(item.dstPath, backupPath);
		}

	if (updating)
	{
		log("Cleaning up existing Digger-installed files...");

		foreach (item; items)
			if (item.name in existingComponents && updateNeeded[item.name])
			{
				log(" - " ~ item.name);
				rmObject(item.dstPath);
			}
	}

	log("Installing new files...");

	foreach (item; items)
		if (item.name !in existingComponents || updateNeeded[item.name])
		{
			log(" - " ~ item.name);
			atomic!cpObject(item.srcPath, item.dstPath);
		}

	version (Posix)
	{
		log("Applying attributes...");

		bool isRoot = geteuid()==0;

		foreach (item; items)
			if (item.name !in existingComponents || updateNeeded[item.name])
			{
				log(" - " ~ item.name);
				item.dstPath.recursive!setMode(mode);

				if (isRoot)
					item.dstPath.recursive!setOwner(owner, group);
				else
					if (item.dstPath.getOwner() != owner || item.dstPath.getGroup() != group)
						log("Warning: UID/GID mismatch for " ~ item.dstPath);
			}
	}

	log("Install OK.");
	log("You can undo this action by running `digger uninstall`.");
}

void uninstall(bool dryRun, bool force, string location = null)
{
	string uninstallPath;
	if (location.canFind(".digger-install"))
		uninstallPath = location;
	else
	{
		auto dmdPath = selectInstallPath(location);
		auto binPath = dmdPath.dirName();
		uninstallPath = buildPath(binPath, ".digger-install");
	}
	auto uninstallFileName = buildPath(uninstallPath, "uninstall.json");
	enforce(uninstallFileName.exists, "Can't find uninstallation data: " ~ uninstallFileName);
	auto uninstallData = uninstallFileName.readText.jsonParse!UninstallData;

	if (!force)
	{
		log("Verifying files to be uninstalled...");

		foreach (obj; uninstallData.objects)
			verifyObject(obj, uninstallPath, "uninstall");

		log("Verify OK.");
	}

	log(dryRun ? "Actions to run:" : "Uninstalling...");

	void runAction(void delegate() action)
	{
		if (!force)
			action();
		else
			try
				action();
			catch (Exception e)
				log("Ignoring error: " ~ e.msg);
	}

	void uninstallObject(InstalledObject* obj)
	{
		auto src = buildNormalizedPath(uninstallPath, obj.name);
		auto dst = buildNormalizedPath(uninstallPath, obj.path);

		if (!src.exists) // --force
		{
			log(" - %s component %s with no backup".format(dryRun ? "Would skip" : "Skipping", obj.name));
			return;
		}

		if (dryRun)
		{
			log(" - Would remove " ~ dst);
			log("   Would move " ~ src ~ " to " ~ dst);
		}
		else
		{
			log(" - Removing " ~ dst);
			runAction({ rmObject(dst); });
			log("   Moving " ~ src ~ " to " ~ dst);
			runAction({ rename(src, dst); });
		}
	}

	foreach (obj; uninstallData.objects)
		runAction({ uninstallObject(obj); });

	if (dryRun)
		return;

	remove(uninstallFileName);

	if (!force)
		rmdir(uninstallPath); // should be empty now
	else
		rmdirRecurse(uninstallPath);

	log("Uninstall OK.");
}

string globFind(string path)
{
	auto results = dirEntries(path.dirName, path.baseName, SpanMode.shallow);
	enforce(!results.empty, "Can't find: " ~ path);
	auto result = results.front;
	results.popFront();
	enforce(results.empty, "Multiple matches: " ~ path);
	return result;
}

void verifyObject(InstalledObject* obj, string uninstallPath, string verb)
{
	auto path = buildPath(uninstallPath, obj.path);
	enforce(path.exists, "Can't find item to %s: %s".format(verb, path));
	auto hash = mdObject(path);
	enforce(hash == obj.hash,
		"Object changed since it was installed: %s\nPlease %s manually.".format(path, verb));
}

version(Posix) bool attrIsExec(int attr) { return (attr & octal!111) != 0; }

/// Set access modes while preserving executable bit.
version(Posix)
void setMode(string fn, int mode)
{
	auto attr = fn.getAttributes();
	mode |= attr & ~octal!777;
	if (attr.attrIsExec || attr.attrIsDir)
		mode = mode | ((mode & octal!444) >> 2); // executable iff readable
	fn.setAttributes(mode);
}

/// Apply a function recursively to all files and directories under given path.
template recursive(alias fun)
{
	void recursive(Args...)(string fn, auto ref Args args)
	{
		fun(fn, args);
		if (fn.isDir)
			foreach (de; fn.dirEntries(SpanMode.shallow))
				recursive(de.name, args);
	}
}

void rmObject(string path) { path.isDir ? path.rmdirRecurse() : path.remove(); }

void cpObject(string src, string dst)
{
	if (src.isDir)
	{
		mkdir(dst);
		dst.setAttributes(src.getAttributes());
		foreach (de; src.dirEntries(SpanMode.shallow))
			cpObject(de.name, buildPath(dst, de.baseName));
	}
	else
	{
		src.copy(dst);
		dst.setAttributes(src.getAttributes());
	}
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
