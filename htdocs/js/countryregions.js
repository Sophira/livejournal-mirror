function CountryRegions (countrySelectId, regionSelectId, regionTextId, zipBoxId, countriesWithRegions) {

    this.countrySelect = document.getElementById(countrySelectId);
    this.regionSelect = document.getElementById(regionSelectId);
    this.regionText = document.getElementById(regionTextId);
    this.zipBox = document.getElementById(zipBoxId);

    this.selectedCountry = '';
    this.loadedCountries = new Object;
    this.countriesWithRegions = new Object;

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

CountryRegions.prototype.countryChanged = function () {
    var self = this;
    this.selectedCountry = this.countrySelect.value;

    if (undefined != this.zipBox) {
        this.zipSwitch();
    }

    if (this.countriesWithRegions[this.selectedCountry] && undefined == this.loadedCountries[this.selectedCountry]) {
        HTTPReq.getJSON({
            method : "POST",
            data : HTTPReq.formEncoded({"country" : self.selectedCountry}),
            url : LiveJournal.getAjaxUrl("load_state_codes"),
            onData : function (regions) { self.onRegionsLoad(regions); },
            onError : LiveJournal.ajaxError
        });
    }

    this.createStatesOptions();
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
        this.regionSelect.style.display = 'block';
        this.regionText.style.display = 'none';
        this.regionText.value = '';
    } else {
        this.regionText.style.display = 'block';
        this.regionSelect.style.display = 'none';
    }
}


CountryRegions.prototype.zipSwitch = function() {
    if (this.selectedCountry == 'US') {
        this.zipBox.disabled = '';
    } else {
        this.zipBox.value = '';
        this.zipBox.disabled = 'disabled';
    }
}
