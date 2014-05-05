var components = ['DMD', 'Druntime', 'Phobos', 'Tools'];

var debug = false;

$(function() {
	$.getJSON('/initialize', function() {
		showTask($('#initialization .log'), function(success) {
			$('#initialization .status').slideUp();
			$('#initialization h1').text('Initialization ' + (success ? 'complete' : 'failed'));
			if (success) {
				createForm();
				showPage('pull-form');
			}
		});
	});
});

function createForm() {
	addSection($('#sections'), 'Open pull requests', function($content, done) {
		var stateRequest;

		$content.append($('#failing-box'));

		$.each(components, function(i, component) {
			var repo = component.toLowerCase();
			addSection($content, component, function($pulls, done) {
				var pullsRequest = $.ajax({
					dataType: 'jsonp',
					url: 'https://api.github.com/repos/D-Programming-Language/'+repo+'/pulls?per_page=100',
					cache: true,
					jsonpCallback : 'jsonpCallback_' + repo
				});
				if (!stateRequest)
					stateRequest = $.getJSON('/pull-state.json');

				$.when(pullsRequest, stateRequest)
					.then(function(pullsResult, stateResult) {
						var stateData = stateResult[0][repo] || {};

						var $table = $('<table>');
						$pulls.append($table);
						$.each(pullsResult[0].data, function(j, pull) {
							var state = stateData[pull.number] || 'unknown';
							if (!pull.mergeable && !pull.merge_commit_sha)
								return;
							var $row = $('<tr>');
							$row.attr('title',
								'Created by ' + pull.user.login + ' on ' + pull.created_at.substr(0, 10) + '. ' +
								'Last updated on ' + pull.updated_at.substr(0, 10) + '.' +
								'\n\n' +
								pull.body
							);
							if (state.state != 'success')
								$row.addClass('bad');

							var $logRow =
								$('<tr>')
								.append(
									$('<td>')
									.css('padding', 0)
								)
								.append(
									$('<td>')
									.attr('colspan', 2)
									.css('padding', 0)
									.append(
										$('<div>')
										.addClass('log')
									)
								)
							;

							var name = repo + '-pull-' + pull.number;
							var checkbox =
								$('<input>')
								.attr('type', 'checkbox')
								.attr('id', name)
								.attr('name', name)
								.data('repo', repo)
								.data('pull', pull.number)
								.click(function() {
									togglePull(this.checked, $row, $logRow.find('div.log'), repo, pull.number);
								})
							;
							$row.append(
								$('<td>')
								.append(checkbox)
							);
							$row.append(
								$('<td>')
								.append(
									$('<label>')
									.attr('for', name)
									.text('#' + pull.number + ': ')
								)
								.append(
									$('<a>')
									.attr('href', pull.html_url)
									.text(pull.title)
								)
							);
							$row.append(
								$('<td>')
								.attr('class', 'status')
								.append(
									$('<a>')
									.attr('class', 'test ' + state.state)
									.attr('href', state.targetUrl)
									.attr('title', state.description)
									.text(stateText[state.state] || state.state)
								)
							);
							$table.append($row);
							$table.append($logRow);
						});
						done();
					}, function() {
						alert('Error retrieving data');
					});
			});

		});

		//$content.append($('#everything-button'));

		$('#show-failing').click(function() {
			$('.bad').toggle(this.checked);
		});

		done();
	}).children('.section-header').children('a').click();

	$('#build-button').click(function() {
		$('input').prop('disabled', true);
		showPage('build-progress');
		$('#build-progress h1').text('Building...');
		$.getJSON('/build', function() {
			showTask($('#build-progress .log'), function(success) {
				$('#build-progress .status').slideUp();
				$('#build-progress h1').text('Build ' + (success ? 'complete' : 'failed'));
			});
		});
	});

	$('#exit-button').click(function() {
		$.getJSON('/exit', function() {
			exit('Exiting', 'You can now close this browser tab.');
			exiting = true;
		});
	});

	$('#everything-button').click(function() {
		$('#everything-button').val('Meditating...');
		var $checkboxes = $('#pulls input:checkbox:visible:not(:checked)');
		var n = 0;

		var enabled = {};

		function next() {
			if (n < $checkboxes.length) {
				var $checkbox = $checkboxes.eq(n++);
				var $row = $checkbox.closest('tr');
				var $logRow = $row.next();
				var $logDiv = $logRow.find('div.log');
				var repo = $checkbox.data('repo');
				var pull = $checkbox.data('pull');

				var id = repo+'#'+pull;
				enabled[id] = 1;
				var conflict = haveConflict(enabled);
				if (conflict) {
					delete enabled[id];
					$logDiv.append(
						$('<a>')
						.text('Skipping - known conflict ('+conflict+')')
						.attr('href', 'http://wiki.dlang.org/Pull_request_conflicts')
					);
					next();
				}
				else
					togglePull(true, $row, $logDiv, repo, pull, next);
			} else {
				$('#build-button').click();
			}
		}

		$("html, body").animate({ scrollTop: "0px" });
		next();
	});
}

var stateText = {
	'success' : 'Tests OK',
	'failure' : 'Tests fail',
	'unknown' : 'Unknown',
};

// ***************************************************************************

function showPage(id) {
	$('#pages > div').slideUp();
	$('#' + id).slideDown();
}

function showTask($logDiv, complete) {
	$.getJSON('/status.json', function(status) {
		for (var i=0; i<status.lines.length; i++) {
			var $line = $('<div>');
			$line.hide();
			$line.text(status.lines[i].text);
			if (status.lines[i].error)
				$line.addClass('error');
			$logDiv.append($line);
			if (status.lines.length > 10)
				$line.show();
			else
				$line.slideDown();
		}
		if (status.lines.length)
			$logDiv.animate({scrollTop: 1e9}, {queue:false});
		if (status.state == 'complete') {
			complete(true);
		} else
		if (status.state == 'error') {
			complete(false);
		} else {
			setTimeout(showTask, debug ? 2000 : 100, $logDiv, complete);
		}
	});
}

function addSection($parent, title, generator) {
	var generated = false;
	var open = false;
	var working = false;

	var $parentSection = $parent.closest('.section, #pages > div');
	var $parentHeader = $parentSection.children('h1,h2,h3,h4,h5,h6,h7');
	var tag = $parentHeader.prop('tagName');

	var $a = $('<a>')
		.text(title)
		.attr('href', '#')
	;
	var $button = $('<img>')
		.attr('src', 'closed.png')
	;
	$a.prepend($button);

	var $h = $('<' + tag[0] + ++tag[1] + '>');
	$h.addClass('section-header');
	$h.append($a);

	var $content = $('<div>');

	$a.click(function() {
		if (working)
			return;

		if (open) {
			$content.slideUp();
			$button.attr('src', 'closed.png');
			open = false;
		} else {
			if (generated) {
				$content.slideDown();
				$button.attr('src', 'open.png');
				open = true;
			} else {
				working = true;
				$button.attr('src', 'loading.gif');
				generator($content, function() {
					$content.slideDown();
					$button.attr('src', 'open.png');
					open = true;
					generated = true;
					working = false;
				});
			}
		}
	});

	var $div = $('<div>')
		.addClass('section')
		.append($h)
		.append($content);

	$content.hide();

	$parent.append($div);

	return $div;
}

// ***************************************************************************

function togglePull(add, $row, $logDiv, repo, number, complete) {
	$('input').prop('disabled', true);
	$logDiv.empty();
	$logDiv.show();
	var $checkbox = $row.find('input[type=checkbox]');
	$checkbox.hide();
	var $spinner = $('<img>').attr('src', 'loading.gif');
	$checkbox.after($spinner);

	function completeHandler(success) {
		$('input').prop('disabled', false);
		$checkbox.prop('checked', add == success);
		$checkbox.show();
		$spinner.remove();
		if (complete)
			complete(success);

		setTimeout(function() {
			if (success) {
				$logDiv.slideUp();
			} else {
				var $logLines = $logDiv.find('div');
				$logLines.slideUp();
				$logDiv.append(
					$('<a>')
					.css('color', 'red')
					.text((add ? 'Merge' : 'Unmerge') + ' failed')
					.attr('href', '#')
					.attr('title', 'View log')
					.click(function() {
						$logLines.slideToggle();
					})
				);
			}
		}, 500);
	}

	var action = add ? 'merge' : 'unmerge';
	$.getJSON('/' + action + '/' +  repo + '/' + number, function() {
		showTask($logDiv, completeHandler);
	});
}

// ***************************************************************************

function wikiGet(title, success) {
	$.ajax('http://wiki.dlang.org/api.php', {
		data : {
			action : 'query',
			prop   : 'revisions',
			rvprop : 'content',
			format : 'json',
			titles : title
		},
		dataType : 'jsonp',
		success : function(data) {
			for (var page in data.query.pages)
				success(data.query.pages[page].revisions[0]['*']);
		}
	});
}

var conflicts = [];

wikiGet('Pull request conflicts', function(text) {
	var lines = text.split(/\r?\n/g);
	for (var i=0; i<lines.length; i++)
		conflicts.push(lines[i].split(/\s+/g));
});

function haveConflict(enabled) {
	function allEnabled(pulls) {
		for (var i=0; i<pulls.length; i++)
			if (!(pulls[i] in enabled))
				return false;
		return true;
	}

	for (var i=0; i<conflicts.length; i++)
		if (allEnabled(conflicts[i]))
			return conflicts[i].join(' ');

	return null;
}

// ***************************************************************************

var pongFailCount = 0;
var exiting = false;

function exit(reason, text) {
	if (exiting)
		return;
	$('body')
		.empty()
		.append($('<h1>').text(reason))
		.append($('<p>').text(text).html())
	;
	exiting = true;
	window.close();
}

var pongTimer = setInterval(function() {
	$.ajax('/ping', {
		timeout : 1000,
		success : function() { pongFailCount = 0; },
		error : function() {
			pongFailCount++;
			if (pongFailCount == 10)
				exit('Connection lost', 'Lost connection to process, exiting.');
			if (exiting)
				clearInterval(pongTimer);
		}
	});
}, debug ? 1e9 : 100);
