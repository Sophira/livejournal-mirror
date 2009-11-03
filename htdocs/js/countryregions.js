function CountryRegions (countrySelectId, regionSelectId, regionTextId, regionDesc, zipBoxId, zipDesc, cityBoxId, cityDesc, countriesWithRegions) {

    this.countrySelect = document.getElementById(countrySelectId);
    this.regionSelect = document.getElementById(regionSelectId);
    this.regionText = document.getElementById(regionTextId);
    this.zipBox = document.getElementById(zipBoxId);
    this.cityBox = document.getElementById(cityBoxId);
    
    var that=this;
    this.descColor = "#999";
    this.regionDesc = regionDesc;
    this.cityDesc = cityDesc;
    this.zipDesc = zipDesc;

    this.selectedCountry = '';
    this.loadedCountries = new Object;
    this.countriesWithRegions = new Object;

    if ($('minimal_display') && $('minimal_display').value == 1) {
        this.minimalDisplay = 1;

        if (this.regionText && this.regionText.value == "") {
            this.regionText.style.color = this.descColor;
            this.regionText.value = this.regionDesc;
        }
        if (this.cityBox && this.cityBox.value == "") {
            this.cityBox.style.color = this.descColor;
            this.cityBox.value = this.cityDesc;
        }
        if (this.zipBox && this.zipBox.value == "") {
            this.zipBox.style.color = this.descColor;
            this.zipBox.value = this.zipDesc;
        }
    } else {
        this.minimalDisplay = 0;
    }

    if (undefined != countriesWithRegions) {
        var exploded = countriesWithRegions.split(/\s+/);
        for (var i = 0; i < exploded.length; i++) {
            this.countriesWithRegions[exploded[i]] = true;
        }
    }

    if(undefined != this.countrySelect) {
        var self = this;
        var listener = function(evt) {
            Event.stop(evt);
            self.countryChanged();
        };
        if (self.countrySelect.attachEvent)
            self.countrySelect.attachEvent('onchange', listener);
        if (self.countrySelect.addEventListener)
            self.countrySelect.addEventListener('change', listener, false);

        if (this.countriesWithRegions[this.countrySelect.value] && this.regionSelect.options.length > 1) {
            var head = this.regionSelect.options[0].text;
            var states = new Array;
            var idx = 0;
            for (var i = 1; i < this.regionSelect.options.length; i++) {
                states[idx++] = this.regionSelect.options[i].value;
                states[idx++] = this.regionSelect.options[i].text;
            }

            this.loadedCountries[this.countrySelect.value] = {head : head, states : states};
        }
    }
}


CountryRegions.prototype.detectRegion=function(data){
   if(this.regionSelect.options.length>0){
	for(var i=0;i<this.regionSelect.options.length;i++){
		if(this.regionSelect.options[i].value==data.data.region_code){
			this.regionSelect.options[i].selected='true';
		}
	}
    }else if(data.data.region_name!=null){
	this.regionText.value=data.data.region_name;	
    }

}

CountryRegions.prototype.countryChanged = function (data) {
    var self = this;
    var that = this;
    this.selectedCountry = this.countrySelect.value;

    if (undefined != this.zipBox) {
        this.zipSwitch();
    }

    if (this.countriesWithRegions[this.selectedCountry] && undefined == this.loadedCountries[this.selectedCountry]) {
        HTTPReq.getJSON({
            method : "POST",
            data : HTTPReq.formEncoded({"country" : self.selectedCountry}),
            url : LiveJournal.getAjaxUrl("load_state_codes"),
            onData : function (regions) {
	    	self.onRegionsLoad(regions);
		if(data){that.detectRegion(data);}
	    },
            onError : LiveJournal.ajaxError
        });
    }
   
    this.createStatesOptions();
    if(data){this.detectRegion(data);} 
}

CountryRegions.prototype.onRegionsLoad = function(regions) {
    this.loadedCountries[this.selectedCountry] = regions;
    this.createStatesOptions();
}

CountryRegions.prototype.createStatesOptions = function() {
    var regions = this.loadedCountries[this.selectedCountry];
    var i;

    this.regionSelect.options.length = 0; // discard previous
    this.regionSelect.value = '';

    if (undefined != regions && undefined != regions.states && regions.states.length > 0) {
        this.regionSelect.options[0] = new Option(regions.head, "");
        for (i = 0; i < regions.states.length / 2; i++) {
            this.regionSelect.options[i + 1] = new Option(regions.states[2 * i + 1], regions.states[2 * i]);
        }
        this.regionSelect.style.display = 'inline';
        this.regionText.style.display = 'none';
        this.regionText.value = '';
    } else {
        this.regionText.style.display = 'inline';
        this.regionSelect.style.display = 'none';

        if (this.minimalDisplay == 1) {
            this.regionText.style.color = this.descColor;
            this.regionText.value = this.regionDesc;
        }
    }
}


CountryRegions.prototype.zipSwitch = function() {
    if (this.minimalDisplay == 1) {
        if (this.selectedCountry == 'US') {
            this.zipBox.style.display = 'inline';
            this.cityBox.style.display = 'none';
            this.cityBox.value = '';

            this.zipBox.style.color = this.descColor;
            this.zipBox.value = this.zipDesc;
        } else {
            this.cityBox.style.display = 'inline';
            this.zipBox.style.display = 'none';
            this.zipBox.value = '';

            this.cityBox.style.color = this.descColor;
            this.cityBox.value = this.cityDesc;
        }
    } else {
        if (this.selectedCountry == 'US') {
            this.zipBox.disabled = '';
        } else {
            this.zipBox.value = '';
            this.zipBox.disabled = 'disabled';
        }
    }
}

CountryRegions.prototype.autoDetect=function(){
	that=this;
	HTTPReq.getJSON({url:'/tools/endpoints/geo_location.bml',
			onData:function(data){
				if(data.data){
					for(var i=0;i<that.countrySelect.options.length;i++){
						if(that.countrySelect.options[i].value==data.data.country_short){
							that.countrySelect.options[i].selected='true';
						}
					}
					that.countryChanged(data);
					if(data.data.city_rus_name){
						that.cityBox.value=data.data.city_rus_name;
					}
					else{
						if(data.data.city_name){
							that.cityBox.value=data.data.city_name;
						}
					}
				}		
			},
			onError:LiveJournal.ajaxError
			});

}
