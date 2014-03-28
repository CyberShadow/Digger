var components = ['DMD', 'Druntime', 'Phobos', 'Tools'];

var debug = false;

$(function() {
	showTask($('#initialization .log'), function() {
		$('#initialization').slideUp();
		$('#pull-form').slideDown();
		getData();
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
			showTask($('#build-progress .log'), function() {
				$('h1').text('Build complete');
			}, function() {
				$('h1').text('Build failed');
			});
		});
	});

	$('#exit-button').click(function() {
		$.getJSON('/exit', function() {
			exit('Exiting', 'You can now close this browser tab.');
			exiting = true;
		});
	});
}

var stateText = {
	'success' : 'Tests OK',
	'failure' : 'Tests fail',
	'unknown' : 'Unknown',
};

function showTask($logDiv, complete, error) {
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
		if (status.state == 'complete') {
			complete();
		} else
		if (status.state == 'error') {
			if (error)
				error();
			else
				alert('Task failed');
		} else {
			setTimeout(showTask, debug ? 2000 : 100, $logDiv, complete, error);
		}
	});
}

function togglePull(add, $row, $logDiv, repo, number) {
	$('input').prop('disabled', true);
	$logDiv.empty();
	$logDiv.show();
	$checkbox = $row.find('input[type=checkbox]');
	$checkbox.hide();
	$spinner = $('<img>').attr('src', 'loading.gif');
	$checkbox.after($spinner);

	function complete(success) {
		$('input').prop('disabled', false);
		$checkbox.prop('checked', add == success);
		$checkbox.show();
		$spinner.remove();

		if (success) {
			$logDiv.slideUp();
		} else {
			$logLines = $logDiv.find('div');
			$logLines.slideUp();
			$logDiv.append(
				$('<div>')
				.css('color', 'red')
				.text('Merge failed')
			);
		}
	}

	var action = add ? 'merge' : 'unmerge';
	$.getJSON('/' + action + '/' +  repo + '/' + number, function() {
		showTask($logDiv, function() {
			setTimeout(complete, 500, true);
		}, function() {
			setTimeout(complete, 500, false);
		});
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
