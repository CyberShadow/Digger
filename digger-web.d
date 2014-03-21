module digger_web;

import std.algorithm;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.functional;
import std.path;
import std.process;
import std.regex;
import std.stdio;
import std.string;

import ae.net.asockets;
import ae.net.http.client;
import ae.net.http.responseex;
import ae.net.http.server;
import ae.net.shutdown;
import ae.sys.timing;
import ae.utils.regex;

import build;
import common;
import repo;

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
version(Windows) static import ae.sys.windows;

// http://d.puremagic.com/issues/show_bug.cgi?id=12481
alias pipe = std.process.pipe;

// ***************************************************************************

class WebFrontend
{
	HttpServer httpd;
	ushort port;

	this()
	{
		httpd = new HttpServer();
		httpd.handleRequest = &onRequest;
		port = httpd.listen(0, "localhost");

		addShutdownHandler(&httpd.close);
	}

	void onRequest(HttpRequest request, HttpServerConnection conn)
	{
		HttpResponseEx resp = new HttpResponseEx();
		
		string resource = request.resource;
		auto segments = resource.split("/")[1..$];
		switch (segments[0])
		{
			case "pull-state.json":
				// Proxy request to GHDaemon, a daemon which caches GitHub
				// pull request test results. Required to avoid GitHub API
				// throttling without exposing a secret authentication token.
				// https://github.com/CyberShadow/GHDaemon
				enforce(resource.startsWith("/"), "Invalid resource");
				return httpRequest(
					new HttpRequest("http://ghdaemon.k3.1azy.net" ~ resource),
					(HttpResponse response, string disconnectReason)
					{
						if (conn.conn.connected)
							conn.sendResponse(response);
					}
				);
			case "status.json":
			{
				enforce(currentTask, "No task was started");

				struct Status
				{
					immutable(Task.OutputLine)[] lines;
					string state;
				}
				Status status;
				status.lines = currentTask.flushLines();
				status.state = text(currentTask.getState()).split(".")[$-1];
				return conn.sendResponse(resp.serveJson(status));
			}
			case "ping":
				lastPing = Clock.currTime;
				return conn.sendResponse(resp.serveJson("OK"));
			case "exit":
				log("Exit requested.");
				shutdown();
				return conn.sendResponse(resp.serveJson("OK"));
			case "merge":
			case "unmerge":
			case "build":
				startTask(segments);
				return conn.sendResponse(resp.serveJson("OK"));
			default:
				return conn.sendResponse(resp.serveFile(resource[1..$], "digger-web/"));
		}
	}
}

// ***************************************************************************

SysTime lastPing;

enum watchdogTimeout = 5.seconds;

void watchdog()
{
	if (exiting)
		return;
	if (lastPing != SysTime.init && Clock.currTime - lastPing > watchdogTimeout)
	{
		log("No ping request in %s, exiting".format(watchdogTimeout));
		return shutdown();
	}
	setTimeout(toDelegate(&watchdog), 100.msecs);
}

bool exiting;

void startWatchdog()
{
	addShutdownHandler({ exiting = true; });
	debug(ASOCKETS) {} else
		watchdog();
}

// ***************************************************************************

class Task
{
	enum State { none, running, error, complete }

	struct OutputLine
	{
		string text;
		bool error;
	}

	this(string[] args...)
	{
		import core.thread;

		void pipeLines(Pipe pipe, bool error)
		{
			// Copy the File to heap
			auto f = [pipe.readEnd].ptr;

			void run()
			{
				while (!f.eof)
				{
					auto s = f.readln();
					if (s.length == 0)
					{
						Thread.sleep(1.msecs);
						continue;
					}
					stderr.write("OE"[error], ": ", s); stderr.flush();
					synchronized(this)
						lines ~= OutputLine(s, error);
				}
			}

			auto t = new Thread(&run);
			t.isDaemon = true;
			t.start();
		}

		auto outPipe = pipe();
		auto errPipe = pipe();

		pipeLines(outPipe, false);
		pipeLines(errPipe, true );

		pid = spawnProcess(
			[thisExePath] ~ args,
			stdin,
			outPipe.writeEnd,
			errPipe.writeEnd,
		);
	}

	State getState()
	{
		auto result = pid.tryWait();
		if (result.terminated)
		{
			if (result.status == 0)
				return State.complete;
			else
				return State.error;
		}
		else
			return State.running;
	}

	immutable(OutputLine)[] flushLines()
	{
		synchronized(this)
		{
			auto result = lines;
			lines = null;
			return result;
		}
	}

private:
	Pid pid;
	immutable(OutputLine)[] lines;
}

Task currentTask;

bool taskRunning()
{
	return currentTask && currentTask.getState() == Task.State.running;
}

void startTask(string[] args...)
{
	assert(!taskRunning(), "A task is already running");
	currentTask = new Task(args);
}

shared static this()
{
	addShutdownHandler({
		if (taskRunning())
		{
			log("Waiting for current task to finish...");
			currentTask.pid.wait();
		}
	 });
}

// ***************************************************************************

void initialize()
{
	if (!repoDir.exists)
		log("First run detected.\nPlease be patient, " ~
			"cloning everything might take a few minutes...\n");

	log("Preparing repository...");
	prepareRepo(true);
	auto repo = Repository(repoDir);

	log("Preparing component repositories...");
	foreach (component; listComponents().parallel)
	{
		auto crepo = Repository(buildPath(repoDir, component));

		log(component ~ ": Resetting repository...");
		crepo.run("reset", "--hard");

		log(component ~ ": Cleaning up...");
		crepo.run("clean", "--force", "-x", "-d", "--quiet");

		log(component ~ ": Fetching pull requests...");
		crepo.run("fetch", "origin", "+refs/pull/*/head:refs/remotes/origin/pr/*");

		log(component ~ ": Creating work branch...");
		crepo.run("checkout", "-B", "custom", "origin/master");
	}

	log("Preparing tools...");
	prepareTools();

	clean();

	log("Ready.");
}

const mergeCommitMessage = "digger-pr-%s-merge";

void merge(string component, string pull)
{
	enforce(component.match(`^[a-z]+$`));
	enforce(pull.match(`^\d+$`));

	auto repo = Repository(buildPath(repoDir, component));

	scope(failure)
	{
		log("Aborting merge...");
		repo.run("merge", "--abort");
	}

	log("Merging...");

	void doMerge()
	{
		repo.run("merge", "--no-ff", "-m", mergeCommitMessage.format(pull), "origin/pr/" ~ pull);
	}

	if (component == "dmd")
	{
		try
			doMerge();
		catch (Exception)
		{
			log("Merge failed. Attempting conflict resolution...");
			repo.run("checkout", "--theirs", "test");
			repo.run("add", "test");
			repo.run("-c", "rerere.enabled=false", "commit", "-m", mergeCommitMessage.format(pull));
		}
	}
	else
		doMerge();

	log("Merge successful.");
}

void unmerge(string component, string pull)
{
	enforce(component.match(`^[a-z]+$`));
	enforce(pull.match(`^\d+$`));

	auto repo = Repository(buildPath(repoDir, component));

	log("Rebasing...");
	environment["GIT_EDITOR"] = "%s unmerge-rebase-edit %s".format(escapeShellFileName(thisExePath), pull);
	// "sed -i \"s#.*" ~ mergeCommitMessage.format(pull).escapeRE() ~ ".*##g\"";
	repo.run("rebase", "--interactive", "--preserve-merges", "origin/master");

	log("Unmerge successful.");
}

void unmergeRebaseEdit(string pull, string fileName)
{
	auto lines = fileName.readText().splitLines();

	bool removing, remaining;
	foreach_reverse (ref line; lines)
		if (line.startsWith("pick "))
		{
			if (line.match(`^pick [0-9a-f]+ ` ~ mergeCommitMessage.format(`\d+`) ~ `$`))
				removing = line.canFind(mergeCommitMessage.format(pull));
			if (removing)
				line = "# " ~ line;
			else
				remaining = true;
		}
	if (!remaining)
		lines = ["noop"];

	std.file.write(fileName, lines.join("\n"));
}

alias resultDir = subDir!"result";

void runBuild()
{
	log("Preparing build...");
	prepareEnv();
	prepareBuilder();

	log("Building...");
	builder.build();

	log("Moving...");
	if (resultDir.exists)
		resultDir.rmdirRecurse();
	rename(buildDir, resultDir);

	log("Build successful.\n\nAdd %s to your PATH to start using it.".format(
		resultDir.buildPath("bin").absolutePath()
	));
}

// ***************************************************************************

/// Try to figure out if this is a desktop machine
/// which can run a graphical web browser, or a
/// headless machine which can't.
/// Either open the URL directly, or just print it
/// and invite the user to do so themselves.
void showURL(ushort port)
{
	auto url = "http://localhost:%s/".format(port);

	version (Windows)
		enum desktop = true;
	else
	version (OSX)
		enum desktop = true;
	else
		bool desktop = environment.get("DISPLAY") != "";

	if (desktop)
	{
		import std.process;
		log("Opening URL: " ~ url);
		browse(url);
	}
	else
	{
		// TODO: replace "localhost" with the server's hostname.
		log("To continue, please browse to: " ~ url);
	}
}

WebFrontend web;

void webMain()
{
	web = new WebFrontend();

	showURL(web.port);

	startTask("initialize");

	startWatchdog();

	socketManager.loop();
}

void doMain()
{
	if (opts.args.length == 0)
		return webMain();
	else
	switch (opts.args[0])  
	{
		case "initialize":
			return initialize();
		case "merge":
			enforce(opts.args.length == 3);
			return merge(opts.args[1], opts.args[2]);
		case "unmerge":
			enforce(opts.args.length == 3);
			return unmerge(opts.args[1], opts.args[2]);
		case "unmerge-rebase-edit":
			enforce(opts.args.length == 3);
			return unmergeRebaseEdit(opts.args[1], opts.args[2]);
		case "build":
			return runBuild();
		default:
			assert(false);
	}
}

int main()
{
	try
	{
		doMain();
		return 0;
	}
	catch (Exception e)
	{
		stderr.writefln("Fatal error: %s", e.msg);
		return 1;
	}
}
