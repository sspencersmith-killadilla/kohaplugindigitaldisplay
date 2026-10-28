package Koha::Plugin::Com::Library::PhotoSignage;

use Modern::Perl;
use base qw(Koha::Plugins::Base);

use C4::Auth qw(get_session);
use C4::Context;
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP qw(decode_json encode_json);
use Koha::Token;
use Koha::Plugin::Com::Library::PhotoSignage::Screens;

our $VERSION = '2.0.2';

our $metadata = {
    name            => 'Photo Signage',
    author          => 'Library Staff',
    description     => 'Manage a public digital-signage slideshow from the Koha staff client.',
    date_authored   => '2026-10-23',
    date_updated    => '2026-10-28',
    minimum_version => '22.11',
    maximum_version => undef,
    version         => $VERSION,
};

use constant MAX_IMAGE_BYTES => 12 * 1024 * 1024;
use constant MAX_VIDEO_BYTES => 250 * 1024 * 1024;
use constant MAX_PDF_BYTES   => 50 * 1024 * 1024;
use constant DEFAULT_INTERVAL => 12;

sub new {
    my ( $class, $args ) = @_;
    $args->{metadata} = $metadata;
    return $class->SUPER::new($args);
}

sub api_namespace { return 'photosignage' }

sub api_routes {
    # In Koha's contrib namespace, omitting x-koha-authorization intentionally
    # permits anonymous reads. Never add a write operation to these routes.
    # GET also handles HEAD in Mojolicious. Explicit HEAD operations make
    # Mojolicious::Plugin::OpenAPI call Route->head, which does not exist.
    return {
        %{ Koha::Plugin::Com::Library::PhotoSignage::Screens::routes() },
        '/slideshow' => { get => {
            'x-mojo-to' => 'Com::Library::PhotoSignage::Public#player',
            operationId => 'photoSignagePlayerGet',
            produces => ['text/html'],
            parameters => [],
            responses => {
                200 => { description => 'Public slideshow player' },
                302 => { description => 'Canonical player address' },
                404 => { description => 'Plugin unavailable' },
                503 => { description => 'Slideshow unavailable' },
            },
        }},
        '/media/{id}' => { get => {
            'x-mojo-to' => 'Com::Library::PhotoSignage::Public#media',
            operationId => 'photoSignageMediaGet',
            produces => [qw(image/jpeg image/png image/gif image/webp video/mp4 application/pdf text/plain)],
            parameters => [{ name => 'id', in => 'path', required => JSON::PP::true, type => 'string' }],
            responses => {
                200 => { description => 'Enabled slide media' },
                206 => { description => 'Partial media content' },
                404 => { description => 'Media not found' },
                416 => { description => 'Range not satisfiable' },
                503 => { description => 'Media unavailable' },
            },
        }},
    };
}

sub public_instance {
    my ($class) = @_;
    return unless C4::Context->config('enable_plugins');
    # Do not turn a private/maintenance catalogue into a public file server.
    return unless C4::Context->preference('OpacPublic');
    return if C4::Context->preference('OPACMaintenance');
    # Base::new can run install/upgrade hooks. Public requests must not do that.
    # These read helpers need only the plugin class for plugin_data lookups.
    my $self = bless { class => $class }, $class;
    return $self->is_enabled ? $self : undef;
}

sub _public_path { return '/api/v1/contrib/photosignage' }

sub _catalogue_base {
    my ($base) = @_;
    $base //= '';
    $base =~ s/\A\s+|\s+\z//g;
    $base =~ s{/+\z}{};
    return $base
        if length($base) <= 2048
        && $base =~ m{\Ahttps?://(?:[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?|\[[a-f0-9:]+\])(?::[0-9]{1,5})?(?:/[^\s?#<>"'\\]*)?\z}i;
    return '';
}

sub _public_player_url {
    my ($self) = @_;
    # OPACBaseURL is Koha's authoritative catalogue address. A per-installation
    # fallback avoids global preference changes on sites where it is absent.
    my $base = _catalogue_base(C4::Context->preference('OPACBaseURL'))
        || $self->_settings->{public_base_url};
    return $base . $self->_public_path . '/slideshow' if length $base;
    # Relative to the staff plugins/run.pl page: preserve the browser's host,
    # scheme, port and any proxy prefix without trusting forwarded-host headers.
    return '../../..' . $self->_public_path . '/slideshow';
}

sub _player_data {
    my ( $self, $asset_base ) = @_;
    my %supported = map { $_ => 1 } qw(image video youtube vimeo webpage text pdf);
    my @active;
    for my $slide ( @{ $self->_slides } ) {
        next unless $slide->{enabled} && $supported{ $slide->{media_type} }
            && ( $slide->{id} // '' ) =~ /\A[a-f0-9-]+\z/;
        # Whitelist display fields; do not expose paths, filenames or staff data.
        my %display = map { $_ => $slide->{$_} } qw(media_type caption text embed_url);
        $display{duration_seconds} = $slide->{duration_seconds};
        $display{asset_url} = $asset_base . $slide->{id} if $slide->{file};
        push @active, \%display;
    }
    my $settings = $self->_settings;
    return {
        slides => \@active,
        interval_seconds => $settings->{interval_seconds},
        fit => $settings->{fit},
    };
}

sub _public_player_html {
    my ($self) = @_;
    require Template;
    # The canonical public page ends in /slideshow (no trailing slash).
    # Resolve assets beside it, on the actual playback host and proxy prefix.
    my $data = $self->_player_data('media/');
    # Render the standalone template directly, without any staff auth helper.
    ( my $directory = File::Spec->rel2abs(__FILE__) ) =~ s/\.pm\z//;
    my $template = Template->new( { ABSOLUTE => 1, ENCODING => 'UTF-8' } );
    my $html = '';
    $template->process( File::Spec->catfile( $directory, 'player.tt' ), $data, \$html )
        or die "Could not render slideshow: " . $template->error . "\n";
    return $html;
}

sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{cgi};
    my $action = $cgi->param('action') // '';
    my $view = $cgi->param('view') // '';
    if ($view eq 'screens' || $view eq 'screen_preview') {
        return Koha::Plugin::Com::Library::PhotoSignage::Screens::tool($self, $view eq 'screen_preview');
    }

    if ( $action eq 'asset' ) {
        return $self->_serve_asset;
    }

    my $message = '';
    my $error   = '';

    if ( uc( $cgi->request_method // 'GET' ) eq 'POST' ) {
        unless ( $self->_valid_csrf ) {
            $error = 'Your session or security token expired. Reload the page and try again.';
        } else {
            eval {
                if ( $action eq 'add' ) {
                    $self->_add_slide;
                    $message = 'Slide added to the playlist.';
                } elsif ( $action eq 'update' ) {
                    $self->_update_slide;
                    $message = 'Slide details saved.';
                } elsif ( $action eq 'move' ) {
                    $self->_move_slide;
                    $message = 'Slideshow order updated.';
                } elsif ( $action eq 'delete' ) {
                    $self->_delete_slide;
                    $message = 'Slide removed from the playlist.';
                } elsif ( $action eq 'settings' ) {
                    $self->_save_settings;
                    $message = 'Slideshow settings saved.';
                } else {
                    die "Unknown action.\n";
                }
            };
            $error = $@ if $@;
        }
    }

    my $slides   = $self->_slides;
    my $settings = $self->_settings;
    my $base_url = $self->_run_url;
    my $csrf     = $self->_csrf_token;
    my $player_url = $self->_public_player_url;

    if ( ( $cgi->param('view') // '' ) eq 'player' ) {
        print $cgi->redirect($player_url);
        return;
    }

    my %type_labels = (
        image   => 'Image',
        video   => 'MP4 video',
        youtube => 'YouTube',
        vimeo   => 'Vimeo',
        webpage => 'Webpage',
        text    => 'Text slide',
        pdf     => 'PDF',
    );
    for my $slide (@$slides) {
        $slide->{type_label} = $type_labels{ $slide->{media_type} } // 'Media';
        $slide->{asset_url} = $base_url . '&action=asset&id=' . $slide->{id}
            if $slide->{file};
        $slide->{source_label} = $slide->{source_url}
            if $slide->{source_url};
        $slide->{screen_usage} = join(', ', @{Koha::Plugin::Com::Library::PhotoSignage::Screens::usage($self, $slide->{id})});
    }
    my $template = $self->get_template( { file => 'manage.tt' } );
    $template->param(
        slides           => $slides,
        settings         => $settings,
        message          => $message || ( $cgi->param('message') // '' ),
        error            => $error,
        csrf_token       => $csrf,
        player_url       => $player_url,
        player_same_server => $player_url !~ m{\Ahttps?://}i,
        max_image_mb     => int( MAX_IMAGE_BYTES / 1024 / 1024 ),
        max_video_mb     => int( MAX_VIDEO_BYTES / 1024 / 1024 ),
        max_pdf_mb       => int( MAX_PDF_BYTES / 1024 / 1024 ),
        slide_count      => scalar @$slides,
        active_count     => scalar grep { $_->{enabled} } @$slides,
    );
    print $cgi->header( -type => 'text/html', -charset => 'UTF-8' );
    print $template->output;
    return;
}

sub _csrf_token {
    my ($self) = @_;
    my $session_cookie = $self->{cgi}->cookie('CGISESSID');
    return '' unless $session_cookie;
    my $session = get_session($session_cookie);
    return '' unless $session;
    return Koha::Token->new->generate_csrf( { session_id => $session->id } ) // '';
}

sub _valid_csrf {
    my ($self) = @_;
    my $session_cookie = $self->{cgi}->cookie('CGISESSID');
    return 0 unless $session_cookie;
    my $session = get_session($session_cookie);
    return 0 unless $session;
    return Koha::Token->new->check_csrf(
        {
            session_id => $session->id,
            token      => scalar $self->{cgi}->param('csrf_token'),
        }
    ) ? 1 : 0;
}

sub _run_url {
    return '/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::Com::Library::PhotoSignage&method=tool';
}

sub _slides {
    my ($self) = @_;
    my $stored = $self->retrieve_data('slides');
    if ( !defined $stored || !length $stored ) {
        # Keep existing installations working: their playlist lives under
        # "photos" and the old records have no media_type field.
        $stored = $self->retrieve_data('photos');
    }
    return [] unless defined $stored && length $stored;
    my $photos = eval { decode_json($stored) };
    die "Could not read the saved slideshow data. Please contact your Koha administrator.\n"
        unless ref($photos) eq 'ARRAY';
    for my $slide (@$photos) {
        die "The saved slideshow contains an invalid entry.\n" unless ref($slide) eq 'HASH';
        $slide->{media_type} //= 'image';
        $slide->{enabled} = $slide->{enabled} ? 1 : 0;
        my $duration = $slide->{duration_seconds} // '';
        $slide->{duration_seconds} = $duration =~ /\A[0-9]+\z/
            && $duration >= 1 && $duration <= 86400 ? 0 + $duration : '';
    }
    return $photos;
}

sub _save_slides {
    my ( $self, $slides ) = @_;
    $self->store_data( { slides => encode_json($slides) } );
}

sub _settings {
    my ($self) = @_;
    my $stored = $self->retrieve_data('settings');
    my $settings = ( defined $stored && length $stored )
        ? eval { decode_json($stored) }
        : {};
    $settings = {} unless ref($settings) eq 'HASH';

    my $interval = $settings->{interval_seconds} // DEFAULT_INTERVAL;
    $interval = DEFAULT_INTERVAL unless $interval =~ /^\d+$/ && $interval >= 3 && $interval <= 600;
    my $fit = $settings->{fit} // 'contain';
    $fit = 'contain' unless $fit eq 'contain' || $fit eq 'cover';

    return {
        interval_seconds => 0 + $interval,
        fit => $fit,
        public_base_url => _catalogue_base($settings->{public_base_url}),
    };
}

sub _upload_dir {
    my ( $self, $read_only ) = @_;
    my $upload_path = C4::Context->config('upload_path');
    $upload_path = $upload_path->[0] if ref($upload_path) eq 'ARRAY';
    die "Koha's upload_path is not configured. Ask your Koha administrator to configure it.\n"
        unless defined $upload_path && length $upload_path;

    my $dir = File::Spec->catdir( $upload_path, 'plugin_data', 'photo-signage' );
    return $dir if $read_only;
    make_path( $dir, { mode => 0750 } ) unless -d $dir;
    die "Media storage is not writable. Check the Koha upload directory permissions.\n"
        unless -w $dir;
    return $dir;
}

sub _add_slide {
    my ($self) = @_;
    my $cgi = $self->{cgi};
    my $type = $cgi->param('media_type') // '';
    my $slides = $self->_slides;
    my $slide = {
        id         => $self->_new_slide_id($slides),
        media_type => $type,
        enabled    => $cgi->param('library_only') ? 0 : 1,
        duration_seconds => _slide_duration($cgi->param('duration_seconds')),
    };
    my $caption = $cgi->param('caption') // '';
    $caption =~ s/^\s+|\s+$//g;
    die "Captions must be 180 characters or fewer.\n" if length($caption) > 180;
    $slide->{caption} = $caption;

    if ( $type eq 'image' || $type eq 'video' || $type eq 'pdf' ) {
        $slide->{file} = $self->_store_uploaded_file($type);
    } elsif ( $type eq 'video_link' ) {
        my ( $provider, $source_url, $embed_url ) =
            _provider_video( $cgi->param('media_url') // '' );
        $slide->{media_type} = $provider;
        $slide->{source_url} = $source_url;
        $slide->{embed_url}  = $embed_url;
    } elsif ( $type eq 'webpage' ) {
        my $source_url = $self->_public_page_url( $cgi->param('media_url') // '' );
        $slide->{source_url} = $source_url;
        $slide->{embed_url}  = $source_url;
    } elsif ( $type eq 'text' ) {
        my $text = $cgi->param('slide_text') // '';
        $text =~ s/^\s+|\s+$//g;
        die "Text slides must contain between 1 and 3,000 characters.\n"
            unless length($text) >= 1 && length($text) <= 3000;
        $slide->{text} = $text;
    } else {
        die "Choose a supported slide type.\n";
    }

    push @$slides, $slide;
    $self->_save_slides($slides);
}

sub _new_slide_id {
    my ( $self, $slides ) = @_;
    my %used = map { ( $_->{id} // '' ) => 1 } @$slides;
    my $id;
    do {
        $id = sprintf( '%x-%x-%08x', time(), $$, int( rand(0xffffffff) ) );
    } while ( $used{$id} );
    return $id;
}

sub _store_uploaded_file {
    my ( $self, $type ) = @_;
    my $cgi = $self->{cgi};
    my $fh  = $cgi->upload('media_file');
    die "Choose a file to upload.\n" unless $fh;

    my %max_bytes = (
        image => MAX_IMAGE_BYTES,
        video => MAX_VIDEO_BYTES,
        pdf   => MAX_PDF_BYTES,
    );
    my $max = $max_bytes{$type} or die "Unsupported upload type.\n";
    my $dir = $self->_upload_dir;
    my $id = $self->_new_slide_id( [] );
    my $temporary_path = File::Spec->catfile( $dir, "$id.uploading" );
    sysopen my $out, $temporary_path, O_WRONLY | O_CREAT | O_EXCL, 0600
        or die "Could not create a temporary media file: $!\n";
    binmode $out;
    binmode $fh;

    my ( $size, $prefix ) = ( 0, '' );
    my $read_error;
    while (1) {
        my $read = read( $fh, my $chunk, 64 * 1024 );
        if ( !defined $read ) {
            $read_error = "Could not read the uploaded file.\n";
            last;
        }
        last if $read == 0;
        $size += $read;
        if ( $size > $max ) {
            $read_error = "This file exceeds the size limit of " . int( $max / 1024 / 1024 ) . " MB.\n";
            last;
        }
        $prefix .= substr( $chunk, 0, 16 - length($prefix) )
            if length($prefix) < 16;
        if ( !print {$out} $chunk ) {
            $read_error = "Could not write the uploaded file: $!\n";
            last;
        }
    }
    my $close_ok = close $out;
    if ( $read_error || !$close_ok ) {
        unlink $temporary_path;
        die $read_error || "Could not finish saving the uploaded file: $!\n";
    }

    my ( $mime, $extension ) = _detect_uploaded_type( $type, $prefix );
    unless ($mime) {
        unlink $temporary_path;
        die "That file is not a valid " . _type_label($type) . ".\n";
    }
    my $filename = "$id.$extension";
    my $final_path = File::Spec->catfile( $dir, $filename );
    unless ( rename $temporary_path, $final_path ) {
        unlink $temporary_path;
        die "Could not finish saving the media file: $!\n";
    }
    chmod 0640, $final_path;
    return $filename;
}

sub _detect_image_type {
    my ($bytes) = @_;
    return ( 'image/jpeg', 'jpg' ) if substr( $bytes, 0, 3 ) eq "\xFF\xD8\xFF";
    return ( 'image/png', 'png' ) if substr( $bytes, 0, 8 ) eq "\x89PNG\r\n\x1A\n";
    return ( 'image/gif', 'gif' ) if substr( $bytes, 0, 6 ) =~ /^GIF8[79]a$/;
    return ( 'image/webp', 'webp' )
        if substr( $bytes, 0, 4 ) eq 'RIFF' && substr( $bytes, 8, 4 ) eq 'WEBP';
    return;
}

sub _detect_uploaded_type {
    my ( $type, $bytes ) = @_;
    return _detect_image_type($bytes) if $type eq 'image';
    return ( 'video/mp4', 'mp4' )
        if $type eq 'video'
        && length($bytes) >= 12
        && substr( $bytes, 4, 4 ) eq 'ftyp';
    return ( 'application/pdf', 'pdf' )
        if $type eq 'pdf' && substr( $bytes, 0, 5 ) eq '%PDF-';
    return;
}

sub _type_label {
    my ($type) = @_;
    my %labels = ( image => 'image', video => 'MP4 video', pdf => 'PDF' );
    return $labels{$type} // 'media file';
}

sub _parse_https_url {
    my ($url) = @_;
    $url =~ s/^\s+|\s+$//g;
    die "Enter an HTTPS URL no longer than 2,048 characters.\n"
        unless length($url) <= 2048 && $url =~ m{\Ahttps://}i;
    die "The URL contains unsupported characters.\n" if $url =~ /[\x00-\x20\x7f]/;
    my ( $host, $port, $rest ) =
        $url =~ m{\Ahttps://([a-z0-9.-]+)(?::(\d+))?([/?#].*)?\z}i;
    die "Enter a valid HTTPS web address.\n" unless $host;
    $host = lc $host;
    $host =~ s/\.$//;
    die "Enter a public website address, not a local or private address.\n"
        if $host !~ /\./
        || $host =~ /^\d+(?:\.\d+){3}$/
        || $host =~ /(?:^|\.)(?:localhost|local|internal|test|invalid|example|home|lan)$/;
    die "The web address has an invalid domain name.\n"
        if length($host) > 253
        || grep { !length($_) || length($_) > 63 || $_ !~ /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/ } split /\./, $host;
    die "Only the standard HTTPS port is supported.\n" if defined $port && $port ne '443';
    my $tld = ( split /\./, $host )[-1];
    die "Enter a public website address with a valid domain ending.\n" unless $tld =~ /[a-z]/;

    my $current_host = lc( ( $_[1] // '' ) );
    $current_host =~ s/:\d+\z//;
    die "Use a public website address, not the Koha staff-client address.\n"
        if length($current_host) && $host eq $current_host;

    return ( "https://$host" . ( $rest // '' ), $host );
}

sub _public_page_url {
    my ($self, $url) = @_;
    my $current_host = $self->{cgi}->http('Host') // '';
    my ( $safe_url, $host ) = _parse_https_url( $url, $current_host );
    return $safe_url;
}

sub _provider_video {
    my ($url) = @_;
    my ( $safe_url, $host ) = _parse_https_url($url);
    my ($path) = $safe_url =~ m{\Ahttps://[^/]+([^?#]*)};
    $path //= '/';

    if ( $host =~ /(?:^|\.)youtube\.com\z/ || $host eq 'youtu.be' ) {
        my $video_id;
        if ( $host eq 'youtu.be' ) {
            ($video_id) = $path =~ m{\A/([A-Za-z0-9_-]{11})(?:/|\z)};
        } elsif ( $path eq '/watch' ) {
            ($video_id) = $safe_url =~ /[?&]v=([A-Za-z0-9_-]{11})(?:&|\z)/;
        } else {
            ($video_id) = $path =~ m{\A/(?:embed|shorts|live)/([A-Za-z0-9_-]{11})(?:/|\z)};
        }
        die "Use a YouTube video link with a valid video ID.\n" unless $video_id;
        return (
            'youtube',
            $safe_url,
            "https://www.youtube-nocookie.com/embed/$video_id?autoplay=1&mute=1&controls=0&playsinline=1&loop=1&playlist=$video_id"
        );
    }

    if ( $host eq 'vimeo.com' || $host eq 'www.vimeo.com' || $host eq 'player.vimeo.com' ) {
        my @segments = grep { length } split m{/}, $path;
        my ($video_id) = reverse grep { /^\d+$/ } @segments;
        die "Use a Vimeo video link with a numeric video ID.\n" unless $video_id;
        return (
            'vimeo',
            $safe_url,
            "https://player.vimeo.com/video/$video_id?autoplay=1&muted=1&loop=1&background=1&dnt=1"
        );
    }

    die "Use a YouTube or Vimeo video link.\n";
}

sub _slide_duration {
    my ($duration) = @_;
    $duration //= '';
    $duration =~ s/^\s+|\s+$//g;
    return '' unless length $duration;
    die "Slide duration must be a whole number from 1 to 86,400 seconds, or blank for automatic timing.\n"
        unless $duration =~ /\A[0-9]+\z/ && $duration >= 1 && $duration <= 86400;
    return 0 + $duration;
}

sub _update_slide {
    my ($self) = @_;
    my $cgi = $self->{cgi};
    my $id = $cgi->param('id') // '';
    die "Invalid slide identifier.\n" unless $id =~ /^[a-f0-9-]+$/;
    my $slides = $self->_slides;
    my ($slide) = grep { $_->{id} eq $id } @$slides;
    die "That slide is no longer in the playlist.\n" unless $slide;
    # Old forms without this field must not erase an existing override.
    my $duration = $cgi->param('duration_seconds');
    $slide->{duration_seconds} = _slide_duration($duration) if defined $duration;

    my $caption = $cgi->param('caption') // '';
    $caption =~ s/^\s+|\s+$//g;
    die "Captions must be 180 characters or fewer.\n" if length($caption) > 180;
    $slide->{caption} = $caption;
    if ( $slide->{media_type} eq 'text' ) {
        my $text = $cgi->param('slide_text') // '';
        $text =~ s/^\s+|\s+$//g;
        die "Text slides must contain between 1 and 3,000 characters.\n"
            unless length($text) >= 1 && length($text) <= 3000;
        $slide->{text} = $text;
    }
    if ($slide->{enabled} && !$cgi->param('enabled')) {
        my $usage = Koha::Plugin::Com::Library::PhotoSignage::Screens::usage($self, $id);
        die "This item is used by " . join(', ', @$usage) . ". Remove those references before disabling it.\n" if @$usage;
    }
    $slide->{enabled} = $cgi->param('enabled') ? 1 : 0;
    $self->_save_slides($slides);
}

sub _move_slide {
    my ($self) = @_;
    my $cgi = $self->{cgi};
    my $id = $cgi->param('id') // '';
    my $direction = $cgi->param('direction') // '';
    die "Invalid slide identifier.\n" unless $id =~ /^[a-f0-9-]+$/;
    die "Invalid move direction.\n" unless $direction eq 'up' || $direction eq 'down';
    my $slides = $self->_slides;
    my ($index) = grep { $slides->[$_]{id} eq $id } 0 .. $#$slides;
    die "That slide is no longer in the playlist.\n" unless defined $index;
    my $target = $direction eq 'up' ? $index - 1 : $index + 1;
    return if $target < 0 || $target > $#$slides;
    my $slide = splice @$slides, $index, 1;
    splice @$slides, $target, 0, $slide;
    $self->_save_slides($slides);
}

sub _delete_slide {
    my ($self) = @_;
    my $id = $self->{cgi}->param('id') // '';
    die "Invalid slide identifier.\n" unless $id =~ /^[a-f0-9-]+$/;
    my $slides = $self->_slides;
    my ($slide) = grep { $_->{id} eq $id } @$slides;
    die "That slide is no longer in the playlist.\n" unless $slide;

    my $usage = Koha::Plugin::Com::Library::PhotoSignage::Screens::usage($self, $id);
    die "This item is used by " . join(', ', @$usage) . ". Remove those references before deleting it.\n" if @$usage;
    if ( $slide->{file} ) {
        my $filename = $slide->{file};
        die "Invalid stored media filename.\n"
            unless $filename =~ /^[a-f0-9-]+\.(?:jpg|png|gif|webp|mp4|pdf)$/;
        my $path = File::Spec->catfile( $self->_upload_dir, $filename );
        unlink $path if -f $path;
    }
    @$slides = grep { $_->{id} ne $id } @$slides;
    $self->_save_slides($slides);
}

sub _save_settings {
    my ($self) = @_;
    my $cgi = $self->{cgi};
    my $interval = $cgi->param('interval_seconds') // '';
    die "Slide duration must be a whole number from 3 to 600 seconds.\n"
        unless $interval =~ /^\d+$/ && $interval >= 3 && $interval <= 600;
    my $fit = $cgi->param('fit') // '';
    die "Choose either fit or fill for the image display.\n"
        unless $fit eq 'contain' || $fit eq 'cover';
    my $public_base = $cgi->param('public_base_url');
    $public_base = $self->_settings->{public_base_url} unless defined $public_base;
    $public_base =~ s/\A\s+|\s+\z//g;
    my $normalized_base = _catalogue_base($public_base);
    die "Enter the full public OPAC address starting with http:// or https://, without a query or fragment, or leave it blank.\n"
        if length($public_base) && !length($normalized_base);
    $self->store_data(
        {
            settings => encode_json(
                {
                    interval_seconds => 0 + $interval,
                    fit              => $fit,
                    public_base_url  => $normalized_base,
                }
            )
        }
    );
}

sub _serve_asset {
    my ($self) = @_;
    my $id = $self->{cgi}->param('id') // '';
    unless ( $id =~ /^[a-f0-9-]+$/ ) {
        print "Status: 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nMedia not found.";
        return;
    }
    my $slides = eval { $self->_slides };
    my ($slide) = $slides && ref($slides) eq 'ARRAY' ? grep { $_->{id} eq $id } @$slides : ();
    unless ($slide) {
        print "Status: 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nMedia not found.";
        return;
    }

    my $filename = $slide->{file} // '';
    unless ( $filename =~ /^[a-f0-9-]+\.(jpg|png|gif|webp|mp4|pdf)$/ ) {
        print "Status: 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nMedia not found.";
        return;
    }
    my $path = File::Spec->catfile( $self->_upload_dir, $filename );
    unless ( -f $path && -r $path ) {
        print "Status: 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nMedia not found.";
        return;
    }

    my %extension_mime = (
        jpg  => 'image/jpeg',
        png  => 'image/png',
        gif  => 'image/gif',
        webp => 'image/webp',
        mp4  => 'video/mp4',
        pdf  => 'application/pdf',
    );
    my ($extension) = $filename =~ /\.([a-z0-9]+)$/;
    my %allowed_extension = (
        image => { map { $_ => 1 } qw(jpg png gif webp) },
        video => { mp4 => 1 },
        pdf   => { pdf => 1 },
    );
    my $content_type =
        $allowed_extension{ $slide->{media_type} }
        && $allowed_extension{ $slide->{media_type} }->{$extension}
        ? $extension_mime{$extension}
        : undef;
    unless ($content_type) {
        print "Status: 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nMedia not found.";
        return;
    }
    open my $in, '<:raw', $path or do {
        print "Status: 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nMedia not found.";
        return;
    };
    my $size = -s $path;
    my ( $start, $end, $status ) = ( 0, $size - 1, 200 );
    my $range = $self->{cgi}->http('Range') // '';
    if ( $range =~ /\Abytes=(\d*)-(\d*)\z/ ) {
        my ( $range_start, $range_end ) = ( $1, $2 );
        if ( $range_start eq '' && $range_end eq '' ) {
            close $in;
            print "Status: 416 Range Not Satisfiable\r\nContent-Range: bytes */$size\r\nContent-Length: 0\r\n\r\n";
            return;
        } elsif ( $range_start eq '' ) {
            my $suffix = 0 + $range_end;
            if ( !$suffix ) {
                close $in;
                print "Status: 416 Range Not Satisfiable\r\nContent-Range: bytes */$size\r\nContent-Length: 0\r\n\r\n";
                return;
            }
            $start = $suffix >= $size ? 0 : $size - $suffix;
        } else {
            $start = 0 + $range_start;
            $end = $range_end eq '' ? $size - 1 : 0 + $range_end;
        }
        if ( $start >= $size || $end < $start ) {
            close $in;
            print "Status: 416 Range Not Satisfiable\r\nContent-Range: bytes */$size\r\nContent-Length: 0\r\n\r\n";
            return;
        }
        $end = $size - 1 if $end >= $size;
        $status = 206;
    } elsif ( $range =~ /\Abytes=/ ) {
        close $in;
        print "Status: 416 Range Not Satisfiable\r\nContent-Range: bytes */$size\r\nContent-Length: 0\r\n\r\n";
        return;
    }

    my $length = $end - $start + 1;
    seek $in, $start, 0;
    binmode STDOUT;
    print "Status: $status " . ( $status == 206 ? "Partial Content" : "OK" ) . "\r\n";
    print "Content-Type: $content_type\r\n";
    print "Content-Length: $length\r\n";
    print "Accept-Ranges: bytes\r\n";
    print "Content-Range: bytes $start-$end/$size\r\n" if $status == 206;
    print "Content-Disposition: inline; filename=\"slide.$extension\"\r\n";
    print "Cache-Control: private, no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n";

    my $remaining = $length;
    while ( $remaining > 0 ) {
        my $wanted = $remaining > 64 * 1024 ? 64 * 1024 : $remaining;
        my $read = read( $in, my $chunk, $wanted );
        last unless defined $read && $read > 0;
        print $chunk;
        $remaining -= $read;
    }
    close $in;
}

sub install {
    my ($self) = @_;
    return 1;
}

sub uninstall {
    my ($self) = @_;
    # Uploaded files are intentionally retained so an accidental uninstall
    # does not silently destroy library media.
    return 1;
}

1;
