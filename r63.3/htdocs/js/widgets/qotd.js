QotD =
{
	skip: 0,
	
	init: function()
	{
		QotD.control = [
			$('prev_questions'),
			$('next_questions'),
			$('prev_questions_disabled'),
			$('next_questions_disabled')
		];
		
		if (!QotD.control[0]) {
			return;
		}
		
		QotD.domain = jQuery('#vertical_name').val() || 'homepage';
		QotD.cache = [$('all_questions').innerHTML];
		
		QotD.control[0].onclick = QotD.prevQuestions;
		QotD.control[1].onclick = QotD.nextQuestions;
		QotD.tryForQuestions();
	},
	
	prevQuestions: function()
	{
		QotD.skip++;
		QotD.getQuestions();
	},
	
	nextQuestions: function()
	{
		QotD.skip--;
		QotD.getQuestions();
	},
	
	tryForQuestions: function()
	{
		var skip =  QotD.skip + 1;
		
		if (QotD.cache[skip] || QotD.get_last == skip) return;
		
		jQuery.getJSON(
			LiveJournal.getAjaxUrl('qotd'),
			{ skip: skip, domain: QotD.domain },
			function(data)
			{
				if (data.text) {
					QotD.cache[skip] = data.text;
				} else {
					QotD.get_last = skip;
				}
				QotD.renederControl();
			}
		);
	},
	
	renederControl: function()
	{
		var len = QotD.cache.length - 1;
		QotD.control[0].style.display = len > QotD.skip ?  'inline' : 'none';
		QotD.control[1].style.display = QotD.skip ? 'inline' : 'none';
		QotD.control[2].style.display = len <= QotD.skip ? 'inline' : 'none';
		QotD.control[3].style.display = !QotD.skip ? 'inline' : 'none';
	},
	
	getQuestions: function()
	{
		QotD.renederControl();
		QotD.cache[QotD.skip] ?
			QotD.printQuestions(QotD.cache[QotD.skip]) :
			jQuery.getJSON(
				LiveJournal.getAjaxUrl('qotd'),
				{skip: QotD.skip, domain: QotD.domain},
				function(data)
				{
					QotD.printQuestions(data.text)
				}
			);
	},
	
	printQuestions: function(text)
	{
		$('all_questions').innerHTML = text;
		QotD.tryForQuestions();
	}
}

jQuery(QotD.init);
