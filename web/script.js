var components = ['DMD', 'Druntime', 'Phobos', 'Tools'];

var debug = false;

$(function() {
	$.getJSON('/initialize', function() {
		showTask($('#initialization .log'), function(success) {
			$('#initialization .status').slideUp();
			$('#initialization h1').text('Initialization ' + (success ? 'complete' : 'failed'));
			if (success) {
				createRefForm();
				showPage('ref-form');
			}
		});
	});
});

function createRefForm() {
	var $section = addSection($('#ref-form'), 'Base revision', function($content, done) {
		$.getJSON('/refs.json', function(refs) {
			function populateSelect($select, arr) {
				$select.empty();
				$.each(arr, function(i, ref) {
					$select.append(
						$('<option>')
						.val(ref)
						.text(ref)
					);
				});
			}
			populateSelect($('#build-base-branches'), refs.branches);
			populateSelect($('#build-base-tags'), refs.tags);
			$('#build-base-branches option[value=master]').prop('selected', true);
			$content.append($('#build-base'));

			$('#build-base').submit(function(event) {
				event.preventDefault();
				$section.slideUp();

				var ref = $('#base-branch').prop('checked') ? $('#build-base-branches').val() : $('#build-base-tags').val();

				$('#ref-form h1').text('Setting base...');
				$.getJSON('/begin/' + ref, function() {
					showTask($('#ref-form .log'), function(success) {
						$('#ref-form h1').text('Setting base ' + (success ? 'complete' : 'failed'));
						if (success) {
							createCustomizationForm();
							showPage('pull-form');
						}
					});
				});
			});

			setTimeout(function() {
				$('#build-base-submit').focus();
			}, 1);

			done();
		});
	}, true);
}

function createCustomizationForm() {
	addSection($('#sections'), 'Build options', function($content, done) {
		$content.append($('#build-options'));
		done();
	});

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
							var $checkbox =
								$('<input>')
								.attr('type', 'checkbox')
								.attr('id', name)
								.attr('name', name)
								.data('repo', repo)
								.data('pull', pull.number)
								.click(function() {
									togglePull(this.checked, $checkbox, $logRow.find('div.log'), repo, pull.number);
								})
							;
							$row.append(
								$('<td>')
								.append($checkbox)
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
						alert('Error retrieving pull/state data');
					});
			});

		});

		$content.append($('#everything-button'));

		$('#show-failing').click(function() {
			$('.bad').toggle(this.checked);
		});

		done();
	}, true).attr('id', 'pulls');

	addSection($('#sections'), 'Forks', function($content, done) {
		$.each(components, function(i, component) {
			var repo = component.toLowerCase();
			addSection($content, component, function($forks, done) {
				githubGetAll('/repos/D-Programming-Language/'+repo+'/forks')
					.then(function(forks) {
						function cmp(a, b) { return a<b ? -1 : a>b ? 1 : 0; }
						forks.sort(function(a, b) { return cmp(a.owner.login.toLowerCase(), b.owner.login.toLowerCase()); });
						$.each(forks, function(i, fork) {
							var $section = addSection($forks, fork.owner.login, function($fork, done) {
								githubGetAll('/repos/'+fork.full_name+'/branches')
									.then(function(branches) {
										var $table = $('<table>');
										$.each(branches, function(i, branch) {
											var $logDiv = $('<div>').addClass('log');
											var id = fork.owner.login + '-' + fork.name + '-' + branch.name;
											$table.append(
												$('<tr>')
												.append(
													$('<td>')
													.append(
														$('<input>')
														.attr('type', 'checkbox')
														.attr('id', id)
														.click(function() {
															toggleFork(this.checked, $(this), $logDiv,
																fork.owner.login, fork.name, branch.name);
														})
													)
												)
												.append(
													$('<td>')
													.append(
														$('<label>')
														.attr('for', id)
														.append(' ')
														.append(
															$('<a>')
															.text(branch.name)
															.attr('href', 'https://github.com/'+fork.full_name+'/compare/'+branch.name)
														)
													)
												)
											);
											$table.append(
												$('<tr>')
												.append($('<td>'))
												.append($('<td>').append($logDiv))
											);
										});
										$fork.append($table);
										done();
									}, function() {
										alert('Error retrieving branch data');
									});
							})
							$section.children('.section-header')
								.append(' (<a href="'+fork.html_url+'">'+fork.full_name+'</a>)');
						});
						done();
					}, function() {
						alert('Error retrieving fork data');
					});
			});
		});

		done();
	}).attr('id', 'forks');

	$('#build-button').click(function() {
		$('input').prop('disabled', true);

		var options = {
			model : $('#build-model').val(),
		};

		showPage('build-progress');
		$('#build-progress h1').text('Building...');
		$.getJSON('/build', options, function() {
			showTask($('#build-progress .log'), function(success) {
				$('#build-progress .status').slideUp();
				$('#build-progress h1').text('Build ' + (success ? 'complete' : 'failed'));
				if (success) {
					$('input').prop('disabled', false);
					$('#preview-install-button').slideDown();
				}
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
		$('input').prop('disabled', true);
		$('#everything-button').val('Meditating...');

		var expandings = $('#pulls .section').map(function() { return expandSection($(this)); }).get();
		$.when.apply($, expandings).then(function() {
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
						togglePull(true, $checkbox, $logDiv, repo, pull, next);
				} else {
					$('#build-button').click();
				}
			}

			next();
		});

		//$("html, body").animate({ scrollTop: "0px" });
	});

	$('#preview-install-button').click(function() {
		$('#preview-install-button').slideUp();

		$('#build-progress h1').text('Install preview');
		$('#build-progress .log').empty().show();

		$.getJSON('/install-preview', function() {
			showTask($('#build-progress .log'), function(success) {
				if (success)
					$('#install-button').slideDown();
			});
		});
	});

	$('#install-button').click(function() {
		$('#install-button').slideUp();

		$('#build-progress h1').text('Installing...');
		$('#build-progress .log').empty();

		$.getJSON('/install', function() {
			showTask($('#build-progress .log'), function(success) {
				$('#build-progress h1').text(success ? 'Install complete' : 'Install error');
			});
		});
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

function addSection($parent, title, generator, autoExpand) {
	var generated = false;
	var open = false;
	var working = false;

	var $parentSection = $parent.closest('.section, #pages > div');
	var $parentHeader = $parentSection.children('h1,h2,h3,h4,h5,h6,h7');
	var tag = $parentHeader.prop('tagName');

	var $h = $('<' + tag[0] + ++tag[1] + '>')
		.addClass('section-header')
		.text(title)
	;
	var $button = $('<img>')
		.attr('src', 'closed.png')
	;
	$h.prepend($button);

	var $content = $('<div>');

	$h.click(function() {
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

	if (autoExpand)
		$h.click();

	return $div;
}

function expandSection($section) {
	var deferred = $.Deferred();
	var $content = $section.children('div');
	if ($content.filter(":visible").length) {
		deferred.resolve();
	} else {
		var $h = $section.children('.section-header');
		$h.click();
		function check() {
			if ($content.filter(":visible").length)
				deferred.resolve();
			else
				setTimeout(check, 100);
		}
		check();
	}
	return deferred.promise();
}

// ***************************************************************************

function toggleMerge(add, $checkbox, $logDiv, resource, complete) {
	$('input').prop('disabled', true);
	$logDiv.empty();
	$logDiv.show();
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

	$.getJSON('/' + resource, function() {
		showTask($logDiv, completeHandler);
	});
}

function togglePull(add, $checkbox, $logDiv, repo, number, complete) {
	var action = add ? 'merge' : 'unmerge';
	var resource = action + '/' + repo + '/' + number;
	toggleMerge(add, $checkbox, $logDiv, resource, complete);
}

function toggleFork(add, $checkbox, $logDiv, user, repo, branch, complete) {
	var action = add ? 'merge-fork' : 'unmerge-fork';
	var resource = action + '/' + user + '/' + repo + '/' + branch;
	toggleMerge(add, $checkbox, $logDiv, resource, complete);
}

// ***************************************************************************

function hashString(s) {
	// from http://stackoverflow.com/a/7616484/21501
	var hash = 0, i, chr, len;
	if (s.length == 0) return hash;
	for (i = 0, len = s.length; i < len; i++) {
		chr   = s.charCodeAt(i);
		hash  = ((hash << 5) - hash) + chr;
		hash |= 0; // Convert to 32bit integer
	}
	return hash;
}

function githubGetAll(resource, maxPages) {
	var deferred = $.Deferred();

	if (!maxPages)
		maxPages = 20;

	var page = 0;
	var allData = [];

	function getNextPage() {
		page++;
		var url = 'https://api.github.com' + resource + '?per_page=100&page=' + page;
		$.ajax({
			dataType: 'jsonp',
			url: url,
			cache: true,
			jsonpCallback : 'jsonpCallback_' + Math.abs(hashString(url))
		}).then(function(response) {
			allData = allData.concat(response.data);
			if (response.data.length == 100 && page < maxPages)
				getNextPage();
			else
				deferred.resolve(allData);
		}, deferred.reject.bind(deferred));
	}

	getNextPage();

	return deferred.promise();
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
		global : false,
		error : function() {
			pongFailCount++;
			if (pongFailCount == 10)
				exit('Connection lost', 'Lost connection to process, exiting.');
			if (exiting)
				clearInterval(pongTimer);
		}
	});
}, debug ? 1e9 : 100);

$(document).ajaxError(function(event, request, settings, errorThrown) {
	alert('HTTP error with request to ' + settings.url + ':\n\n' + errorThrown + '\n\n' + request.responseText);
});
