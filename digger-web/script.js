var components = ['DMD', 'Druntime', 'Phobos', 'Tools'];

var debug = false;

$(function() {
	showTask($('#initialization .log'), function(success) {
		$('#initialization .status').slideUp();
		$('#initialization h1').text('Initialization ' + (success ? 'complete' : 'failed'));
		if (success) {
			$('#initialization').slideUp();
			$('#pull-form').slideDown();
			getData();
		}
	});
});

function getData() {
	var stateRequest = $.getJSON('/pull-state.json');
	$.each(components, function(i, component) {
		var repo = component.toLowerCase();
		var $div = $('<div>');
		$div.append($('<h2>').text(component));
		var $pulls = $('<div><img src="loading.gif"> Loading pull requests...</div>');
		$div.append($pulls);
		$('#repos').append($div);
		var pullsRequest = $.ajax({
			dataType: 'jsonp',
			url: 'https://api.github.com/repos/D-Programming-Language/'+repo+'/pulls?per_page=100',
			cache: true,
			jsonpCallback : 'jsonpCallback_' + repo
		});
		$.when(pullsRequest, stateRequest)
			.then(function(pullsResult, stateResult) {
				var stateData = stateResult[0][repo] || {};

				$pulls.html('');
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
			}, function() {
				alert('Error retrieving data');
			});
	});

	$('#show-failing').click(function() {
		$('.bad').toggle(this.checked);
	});

	$('#build-button').click(function() {
		$('input').prop('disabled', true);
		$('#pull-form').slideUp();
		$('#build-progress').slideDown();
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
		var $checkboxes = $('#repos input:checkbox:visible:not(:checked)');
		var n = 0;

		function next() {
			if (n < $checkboxes.length) {
				var $checkbox = $checkboxes.eq(n++);
				var $row = $checkbox.closest('tr');
				var $logRow = $row.next();
				var repo = $checkbox.data('repo');
				var pull = $checkbox.data('pull');
				togglePull(true, $row, $logRow.find('div.log'), repo, pull, next);
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

function showTask($logDiv, complete) {
	$.getJSON('/status.json', function(status) {
		for (var i=0; i<status.lines.length; i++) {
			var $line = $('<div>');
			$line.hide();
			$line.text(status.lines[i].text);
			if (status.lines[i].error)
				$line.addClass('error');
			$logDiv.append($line);
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
