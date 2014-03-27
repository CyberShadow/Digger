module digger_web;

import std.conv;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.regex;
import std.stdio;
import std.string;

import ae.net.asockets;
import ae.net.http.client;
import ae.net.http.responseex;
import ae.net.http.server;

import build;
import common;
import repo;

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
version(Windows) static import ae.sys.windows;

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
				struct Status
				{
					immutable(Task.OutputLine)[] lines;
					string state;
				}
				enforce(currentTask, "No task was started");
				auto status = Status(currentTask.flushLines(), text(currentTask.getState()).split(".")[$-1]);
				return conn.sendResponse(resp.serveJson(status));
			}
			case "merge":
			case "unmerge":
				startTask(segments);
				return conn.sendResponse(resp.serveJson("OK"));
			default:
				return conn.sendResponse(resp.serveFile(resource[1..$], "digger-web/"));
		}
	}
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

void startTask(string[] args...)
{
	assert(!currentTask || currentTask.getState() != Task.State.running, "A task is already running");
	currentTask = new Task(args);
}

// ***************************************************************************

void initialize()
{
	log("Preparing repository...");
	prepareRepo(true);
	auto repo = Repository(repoDir);

	log("Preparing tools...");
	prepareTools();

	log("Cleaning up...");
	repo.run("submodule", "foreach", "git", "reset", "--hard");
	repo.run("submodule", "foreach", "git", "clean", "--force", "-x", "-d", "--quiet");

	log("Creating work branch...");
	repo.run("submodule", "foreach", "git", "checkout", "-B", "custom", "origin/master");

	log("Ready.");
}

void merge(string component, string pull)
{
	enforce(component.match(`^[a-z]+$`));
	enforce(pull.match(`^\d+$`));

	auto repo = Repository(buildPath(repoDir, component));
	log("Fetching " ~ component ~ " pull request #" ~ pull ~ "...");
	repo.run("fetch", "origin", "refs/pull/" ~ pull ~ "/head");

	scope(failure)
	{
		log("Aborting merge...");
		repo.run("merge", "--abort");
	}

	log("Merging...");
	repo.run("merge", "FETCH_HEAD");

	log("Merge successful.");
}

void unmerge(string component, string pull)
{
	enforce(component.match(`^[a-z]+$`));
	enforce(pull.match(`^\d+$`));

	auto repo = Repository(buildPath(repoDir, component));

	log("Rebasing...");
	environment["GIT_EDITOR"] = "sed -i \"s#.*refs/pull/" ~ pull ~ "/head.*##g\"";
	repo.run("rebase", "--interactive", "--preserve-merges", "origin/master");

	log("Unmerge successful.");
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

void webMain()
{
	auto web = new WebFrontend();

	showURL(web.port);

	startTask("initialize");

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
		default:
			assert(false);
	}
}

int main()
{
	// https://d.puremagic.com/issues/show_bug.cgi?id=6423
	doMain();
	return 0;
}
