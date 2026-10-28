package Koha::Plugin::Com::Library::PhotoSignage::Public;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::Asset::File;
use File::Spec;
use Koha::Plugin::Com::Library::PhotoSignage;

sub _headers {
    my ($c) = @_;
    $c->res->headers->header( 'Cache-Control' => 'no-store, max-age=0' );
    $c->res->headers->header( 'X-Content-Type-Options' => 'nosniff' );
    $c->res->headers->header( 'X-Robots-Tag' => 'noindex, nofollow, noarchive' );
    $c->res->headers->header( 'Referrer-Policy' => 'strict-origin-when-cross-origin' );
}

sub _read_method {
    my ($c) = @_;
    return 1 if $c->req->method eq 'GET' || $c->req->method eq 'HEAD';
    $c->res->headers->allow('GET, HEAD');
    $c->render( status => 405, text => 'Method not allowed.' );
    return;
}

sub _plugin {
    my ($c) = @_;
    my $plugin;
    my $ok = eval {
        $plugin = Koha::Plugin::Com::Library::PhotoSignage->public_instance;
        1;
    };
    unless ($ok) {
        $c->app->log->error("Photo Signage public access failed: $@");
        $c->render( status => 503, text => 'Slideshow temporarily unavailable.' );
        return;
    }
    unless ($plugin) {
        $c->render( status => 404, text => 'Slideshow not found.' );
        return;
    }
    return $plugin;
}

sub player {
    my ($c) = @_;
    _headers($c);
    return unless _read_method($c);
    my $plugin = _plugin($c) or return;
    # Some routers accept a trailing slash. Canonicalize before using relative
    # media URLs; the relative redirect also preserves an external proxy prefix.
    if ( $c->req->url->path->to_string =~ m{/slideshow(/+)\z} ) {
        # redirect_to normalizes against the internal request path, which may
        # have had its external prefix stripped by a proxy. Keep Location relative.
        $c->res->headers->location(('../' x length($1)) . 'slideshow');
        return $c->render( status => 302, text => '' );
    }
    my $html = eval { $plugin->_public_player_html };
    if ($@) {
        $c->app->log->error("Photo Signage player failed: $@");
        return $c->render( status => 503, text => 'Slideshow temporarily unavailable.' );
    }
    return $c->render( status => 200, format => 'html', text => $html );
}

sub media {
    my ($c) = @_;
    _headers($c);
    return unless _read_method($c);
    my $id = $c->stash('id') // '';
    return $c->render( status => 404, text => 'Media not found.' )
        unless length($id) <= 128 && $id =~ /\A[a-f0-9-]+\z/;
    my $plugin = _plugin($c) or return;
    # Always reread enabled state, even if an old player still has this URL.
    my $slides = eval { $plugin->_slides };
    if ($@) {
        $c->app->log->error("Photo Signage playlist failed: $@");
        return $c->render( status => 503, text => 'Media temporarily unavailable.' );
    }
    my $slide;
    eval {
        ($slide) = grep { $_->{enabled} && ( $_->{id} // '' ) eq $id } @$slides;
        $slide ||= Koha::Plugin::Com::Library::PhotoSignage::Screens::public_media($plugin, $id);
        1;
    } or return $c->render(status => 503, text => 'Media temporarily unavailable.');
    my $filename = $slide ? ( $slide->{file} // '' ) : '';
    return $c->render( status => 404, text => 'Media not found.' )
        unless $filename =~ /\A[a-f0-9-]+\.(jpg|png|gif|webp|mp4|pdf)\z/;
    my $extension = $1;
    my %mime = (
        image => { jpg => 'image/jpeg', png => 'image/png', gif => 'image/gif', webp => 'image/webp' },
        video => { mp4 => 'video/mp4' },
        pdf   => { pdf => 'application/pdf' },
    );
    my $type = $mime{ $slide->{media_type} // '' };
    my $content_type = $type ? $type->{$extension} : undef;
    return $c->render( status => 404, text => 'Media not found.' ) unless $content_type;
    my $path = eval { File::Spec->catfile( $plugin->_upload_dir(1), $filename ) };
    if ($@) {
        $c->app->log->error("Photo Signage storage failed: $@");
        return $c->render( status => 503, text => 'Media temporarily unavailable.' );
    }
    return $c->render( status => 404, text => 'Media not found.' )
        unless -f $path && -r $path && !-l $path;

    # File-backed responses avoid loading a 250 MB video into Perl memory.
    my $asset;
    my $size = eval {
        $asset = Mojo::Asset::File->new( path => $path );
        $asset->size;
    };
    return $c->render( status => 404, text => 'Media not found.' ) if $@;
    my $range = _range( $size, $c->req->headers->range // '' );
    $c->res->headers->accept_ranges('bytes');
    unless ($range) {
        $c->res->headers->content_range("bytes */$size");
        return $c->render( status => 416, data => '' );
    }
    my ( $status, $start, $end, $length ) = @$range;
    $c->res->headers->content_type($content_type);
    $c->res->headers->content_disposition("inline; filename=\"slide.$extension\"");
    $c->res->headers->content_length($length);
    $c->res->headers->content_range("bytes $start-$end/$size") if $status == 206;
    $asset->start_range($start)->end_range($end) if $size > 0;
    $c->res->content->asset($asset);
    # Mojolicious suppresses the body for HEAD while preserving GET headers.
    return $c->rendered($status);
}

sub screen { return _screen_response($_[0], 0) }
sub revision { return _screen_response($_[0], 1) }

sub _screen_response {
    my ($c, $revision) = @_;
    _headers($c);
    return unless _read_method($c);
    my $plugin = _plugin($c) or return;
    my $id = $c->stash('id') // '';
    my $entry;
    eval { $entry = Koha::Plugin::Com::Library::PhotoSignage::Screens::_entry($plugin, 'screens', $id); 1 }
        or return $c->render(status => 503, text => 'Screen temporarily unavailable.');
    return $c->render(status => 404, text => 'Screen not found.')
        unless $entry && $entry->{enabled} && $entry->{published};
    if (!$revision && $c->req->url->path->to_string =~ m{/screens/\Q$id\E(/+)\z}) {
        $c->res->headers->location(('../' x length($1)) . $id);
        return $c->render(status => 302, text => '');
    }
    return $c->render(json => { revision => 0 + $entry->{revision} }) if $revision;
    my $html = eval { Koha::Plugin::Com::Library::PhotoSignage::Screens::player_html($plugin, $entry, 0) };
    if ($@) {
        $c->app->log->error("Photo Signage screen failed: $@");
        return $c->render(status => 503, text => 'Screen temporarily unavailable.');
    }
    return $c->render(status => 200, format => 'html', text => $html);
}

sub _range {
    my ( $size, $header ) = @_;
    return [ 200, 0, $size - 1, $size ] unless length $header;
    return unless $size > 0 && $header =~ /\Abytes=(\d{0,20})-(\d{0,20})\z/;
    my ( $first, $last ) = ( $1, $2 );
    return if $first eq '' && $last eq '';
    my ( $start, $end ) = ( 0, $size - 1 );
    if ( $first eq '' ) {
        my $suffix = 0 + $last;
        return unless $suffix > 0;
        $start = $suffix >= $size ? 0 : $size - $suffix;
    } else {
        $start = 0 + $first;
        $end = 0 + $last if length $last;
    }
    return if $start >= $size || $end < $start;
    $end = $size - 1 if $end >= $size;
    return [ 206, $start, $end, $end - $start + 1 ];
}

1;
