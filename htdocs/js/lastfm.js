LJ.LastFM = {
    /*
     * Get current playing (or just listened) track in last.fm
     * http://www.last.fm/api/show/user.getRecentTracks
     * @param {String} user LastFM username
     * @param {Function(Object)} callback Argument is the current track, see last.fm API
     */
    getNowPlaying: function(user, callback) {
        'use strict';

        jQuery.ajax({
            url: 'http://ws.audioscrobbler.com/2.0/',
            dataType: 'json',
            cache: false,
            data: {
                method: 'user.getrecenttracks',
                user: user,
                api_key: Site.page.last_fm_api_key,
                format: 'json'
            }
        }).done(function(res) {
            if (res.error) {
                console.error('Last.FM error: ' + res.message);
                return;
            }

            var tracks = res.recenttracks,
                last = tracks && tracks.track[0],
                nowPlaying = null,
                date = null,
                justListened = false;

            if (last.name && last.artist && last.artist.name) {

                if (last.date) {
                    date = +new Date(Number(last.date.uts) * 1000),
                    justListened = +new Date() - date < 300000;
                }

                if ((last['@attr'] && last['@attr'].nowplaying) || justListened) {
                    nowPlaying = {
                        artist: last.artist.name,
                        name: last.name,
                        _: last
                    };
                }
            }

            if (callback) {
                callback(nowPlaying);
            }
        });
    }
};

function lastfm_current ( username, show_error ) {
    'use strict';

    var user = Site.page.last_fm_user;
    if (!user) {
        console.error('No last.fm user');
        return;
    }

    var input = document.getElementById('prop_current_music');

    input.value = 'Loading...';
    LJ.LastFM.getNowPlaying(user, function(track) {
        if (track) {
            input.value = '{artist} - {name} | Powered by Last.fm'.supplant(track);
        } else {
            input.value = '';
        }
    });
}

if (Site.page.ljpost) {
    jQuery(function() {
        lastfm_current();
    });
}