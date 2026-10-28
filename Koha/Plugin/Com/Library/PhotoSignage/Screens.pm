package Koha::Plugin::Com::Library::PhotoSignage::Screens;

use Modern::Perl;
use JSON::PP qw(encode_json decode_json);
use File::Spec;
use Encode qw(encode_utf8);

sub routes {
    my %routes;
    for my $route (
        ['/screens/{id}', 'screen', 'text/html'],
        ['/screens/{id}/revision', 'revision', 'application/json'],
    ) {
        $routes{$route->[0]} = { get => {
            'x-mojo-to' => 'Com::Library::PhotoSignage::Public#' . $route->[1],
            operationId => 'photoSignage' . ucfirst($route->[1]) . 'Get',
            produces => [$route->[2]],
            parameters => [{ name => 'id', in => 'path', required => JSON::PP::true, type => 'string' }],
            responses => {
                200 => { description => 'Published screen content' },
                302 => { description => 'Canonical screen address' },
                404 => { description => 'Screen unavailable' },
                503 => { description => 'Temporary failure' },
            },
        }};
    }
    return \%routes;
}
# Kept separate from the legacy playlist: existing installations need no rewrite.
# Each entry is stored separately, avoiding an unbounded plugin_data value.
sub _index {
    my ($plugin) = @_;
    my $raw = $plugin->retrieve_data('signage_index_v1');
    return { version => 1, screens => [], templates => [] } unless defined $raw && length $raw;
    my $index = decode_json($raw);
    die "Invalid signage index.\n" unless ref($index) eq 'HASH'
        && $index->{version} == 1 && ref($index->{screens}) eq 'ARRAY' && ref($index->{templates}) eq 'ARRAY';
    return $index;
}

sub _entry {
    my ($plugin, $kind, $id) = @_;
    return unless defined $id && $id =~ /\A[a-f0-9-]{1,128}\z/;
    my $index = _index($plugin);
    return unless grep { $_ eq $id } @{$index->{$kind}};
    my $raw = $plugin->retrieve_data("signage_${kind}_$id");
    die "Missing signage entry. Please contact your administrator.\n" unless defined $raw && length $raw;
    my $entry = decode_json($raw);
    die "Invalid signage entry.\n" unless ref($entry) eq 'HASH' && $entry->{id} eq $id;
    return $entry;
}

sub _put {
    my ($plugin, $kind, $entry) = @_;
    my $index = _index($plugin);
    unless (grep { $_ eq $entry->{id} } @{$index->{$kind}}) {
        die "You can have up to 50 $kind.\n" if @{$index->{$kind}} >= 50;
        push @{$index->{$kind}}, $entry->{id};
    }
    $plugin->store_data({
        "signage_${kind}_$entry->{id}" => encode_json($entry),
        signage_index_v1 => encode_json($index),
    });
}

sub _remove {
    my ($plugin, $kind, $id) = @_;
    my $index = _index($plugin);
    @{$index->{$kind}} = grep { $_ ne $id } @{$index->{$kind}};
    $plugin->store_data({ signage_index_v1 => encode_json($index), "signage_${kind}_$id" => '' });
}

sub _copy { return decode_json(encode_json($_[0])) }
sub _name {
    my ($name) = @_;
    $name //= '';
    $name =~ s/^\s+|\s+$//g;
    die "Enter a name between 1 and 100 characters.\n" unless length($name) && length($name) <= 100;
    return $name;
}
sub _number {
    my ($value, $min, $max, $label) = @_;
    die "$label must be a number from $min to $max.\n"
        if !defined($value) || ref($value) || $value !~ /\A[0-9]+(?:\.[0-9]{1,4})?\z/
        || $value < $min || $value > $max;
    return 0 + $value;
}
sub _text {
    my ($value, $max) = @_;
    $value //= '';
    die "A text field is too long or invalid (maximum $max characters).\n" if ref($value) || length($value) > $max;
    return "$value";
}
sub _color {
    my ($value, $default) = @_;
    $value //= $default;
    die "Choose a six-digit hex color.\n" unless $value =~ /\A#[0-9a-f]{6}\z/i;
    return $value;
}

sub starters {
    my $clock = { id => 'clock', type => 'clock', x => 0, y => 0, w => 100, h => 18,
        timezone => 'UTC', clock_format => 'datetime', font_size => 40, background => '#12233b', color => '#ffffff' };
    my $playlist = { id => 'photos', type => 'playlist', x => 0, y => 18, w => 60, h => 82, items => [] };
    return [
        { id => 'blank', name => 'Blank landscape', layout => { width => 1920, height => 1080, background => '#05070b', regions => [] } },
        { id => 'split', name => 'Clock and two sections', layout => { width => 1920, height => 1080, background => '#05070b',
            regions => [ $clock, $playlist, { id => 'notice', type => 'text', x => 60, y => 18, w => 40, h => 82,
                text => 'Welcome to the library', font_size => 52, color => '#ffffff', background => '#193b42' } ] } },
        { id => 'portrait', name => 'Portrait noticeboard', layout => { width => 1080, height => 1920, background => '#05070b',
            regions => [ { %$clock, h => 15 }, { %$playlist, y => 15, w => 100, h => 85 } ] } },
    ];
}

sub validate_layout {
    my ($plugin, $input) = @_;
    die "Invalid layout.\n" unless ref($input) eq 'HASH' && ref($input->{regions}) eq 'ARRAY';
    die "A layout supports up to 24 sections.\n" if @{$input->{regions}} > 24;
    my $layout = {
        width => _number($input->{width}, 240, 4096, 'Width'),
        height => _number($input->{height}, 240, 4096, 'Height'),
        background => _color($input->{background}, '#05070b'), regions => [],
    };
    my %media = map { $_->{id} => $_ } @{$plugin->_slides};
    my %ids;
    for my $source (@{$input->{regions}}) {
        die "Invalid section.\n" unless ref($source) eq 'HASH';
        my $id = $source->{id} // '';
        die "Sections must have unique identifiers.\n" unless $id =~ /\A[a-z0-9-]{1,60}\z/i && !$ids{$id}++;
        my $type = $source->{type} // '';
        die "Unsupported section type.\n" unless $type =~ /\A(?:clock|text|playlist|youtube|vimeo|webpage|code)\z/;
        my $region = { id => $id, type => $type };
        for my $field (qw(x y w h)) {
            $region->{$field} = _number($source->{$field}, $field =~ /[wh]/ ? 1 : 0, 100, $field);
        }
        die "Keep the section within the screen boundaries.\n"
            if $region->{x} + $region->{w} > 100.001 || $region->{y} + $region->{h} > 100.001;
        $region->{background} = _color($source->{background}, '#05070b');
        $region->{color} = _color($source->{color}, '#ffffff');
        $region->{font_size} = _number($source->{font_size} // 40, 12, 180, 'Font size');
        $region->{fit} = $source->{fit} // 'contain';
        die "Choose contain or cover.\n" unless $region->{fit} =~ /\A(?:contain|cover)\z/;
        $region->{interval_seconds} = _number($source->{interval_seconds} // 12, 1, 86400, 'Interval');
        if ($type eq 'clock') {
            my $zone = _text($source->{timezone} // 'UTC', 100);
            die "Use UTC or an IANA timezone such as America/Chicago.\n"
                unless $zone eq 'UTC' || $zone =~ /\A[A-Za-z_+-]+(?:\/[A-Za-z0-9_+-]+){1,3}\z/;
            $region->{timezone} = $zone;
            $region->{clock_format} = $source->{clock_format} // 'datetime';
            die "Choose date, time, or datetime.\n" unless $region->{clock_format} =~ /\A(?:date|time|datetime)\z/;
            $region->{hour12} = $source->{hour12} ? JSON::PP::true : JSON::PP::false;
        } elsif ($type eq 'text') {
            $region->{text} = _text($source->{text}, 6000);
        } elsif ($type eq 'code') {
            $region->{$_} = _text($source->{$_}, 12000) for qw(html css js);
        } elsif ($type eq 'playlist') {
            die "Choose up to 200 media items.\n" unless ref($source->{items}) eq 'ARRAY' && @{$source->{items}} <= 200;
            $region->{items} = [];
            for my $item (@{$source->{items}}) {
                die "A selected media item no longer exists.\n"
                    unless ref($item) eq 'HASH' && defined $item->{id} && exists $media{$item->{id}};
                push @{$region->{items}}, { id => $item->{id},
                    duration_seconds => Koha::Plugin::Com::Library::PhotoSignage::_slide_duration($item->{duration_seconds}) };
            }
        } else {
            my $url = _text($source->{url}, 2048);
            $region->{url} = $url;
            if ($type eq 'webpage') {
                my $staff_host = $plugin->{cgi} && $plugin->{cgi}->can('http') ? ($plugin->{cgi}->http('Host') // '') : '';
                ($region->{embed_url}) = Koha::Plugin::Com::Library::PhotoSignage::_parse_https_url($url, $staff_host);
            } else {
                my ($provider, undef, $embed) = Koha::Plugin::Com::Library::PhotoSignage::_provider_video($url);
                die "Choose a $type URL for this section.\n" unless $provider eq $type;
                $region->{embed_url} = $embed;
            }
        }
        push @{$layout->{regions}}, $region;
    }
    die "The layout is too large. Reduce code or playlist sections.\n" if length(encode_json($layout)) > 55000;
    return $layout;
}

sub _snapshot {
    my ($plugin, $layout) = @_;
    $layout = _copy($layout);
    my %media = map { $_->{id} => $_ } @{$plugin->_slides};
    for my $region (@{$layout->{regions}}) {
        next unless $region->{type} eq 'playlist';
        $region->{slides} = [];
        for my $item (@{$region->{items}}) {
            my $slide = $media{$item->{id}} or die "A selected media item no longer exists.\n";
            if ($slide->{file}) {
                die "Invalid stored media filename.\n" unless $slide->{file} =~ /\A[a-f0-9-]+\.(?:jpg|png|gif|webp|mp4|pdf)\z/;
                my $path = File::Spec->catfile($plugin->_upload_dir(1), $slide->{file});
                die "A selected media file is missing or unreadable.\n" unless -f $path && -r $path && !-l $path;
            }
            my %display = map { $_ => $slide->{$_} } qw(id media_type caption text embed_url file duration_seconds);
            $display{duration_seconds} = $item->{duration_seconds} if length($item->{duration_seconds} // '');
            push @{$region->{slides}}, \%display;
        }
    }
    die "Published layout is too large; reduce the selected content.\n" if length(encode_json($layout)) > 60000;
    return $layout;
}

sub usage {
    my ($plugin, $media_id) = @_;
    my $index = _index($plugin);
    my @uses;
    for my $kind (qw(screens templates)) {
        for my $id (@{$index->{$kind}}) {
            my $entry = _entry($plugin, $kind, $id);
            for my $field ($kind eq 'screens' ? qw(draft published) : ('layout')) {
                next unless $entry->{$field};
                my $found = grep { my $region = $_; grep { $_->{id} eq $media_id } @{$region->{items} // []} }
                    @{$entry->{$field}{regions}};
                push @uses, "$entry->{name} ($field)" if $found;
            }
        }
    }
    return \@uses;
}

sub public_media {
    my ($plugin, $media_id) = @_;
    for my $id (@{_index($plugin)->{screens}}) {
        my $entry = _entry($plugin, 'screens', $id);
        next unless $entry->{enabled} && $entry->{published};
        for my $region (@{$entry->{published}{regions}}) {
            for my $slide (@{$region->{slides} // []}) {
                return $slide if $slide->{id} eq $media_id;
            }
        }
    }
    return;
}

sub screen_url {
    my ($plugin, $id) = @_;
    (my $url = $plugin->_public_player_url) =~ s{/slideshow\z}{/screens/$id};
    return $url;
}

sub command {
    my ($plugin) = @_;
    my $cgi = $plugin->{cgi};
    my $action = $cgi->param('screen_action') // '';
    my $id = $cgi->param('id') // '';
    my $kind = $action =~ /^template_/ ? 'templates' : 'screens';
    my $entry = length($id) ? _entry($plugin, $kind, $id) : undef;
    if ($action eq 'create') {
        my $source_id = $cgi->param('template_id') // '';
        $source_id = 'blank' unless length $source_id;
        my ($source) = grep { $_->{id} eq $source_id } @{starters()};
        $source ||= _entry($plugin, 'templates', $source_id);
        die "Template not found.\n" unless $source;
        my $layout = validate_layout($plugin, _copy($source->{layout}));
        $entry = { id => $plugin->_new_slide_id([]), name => _name($cgi->param('name')),
            enabled => 0, revision => 0, draft => $layout, published => undef };
    } elsif ($action eq 'save' || $action eq 'publish' || $action eq 'template_save') {
        die "Screen not found.\n" if $action ne 'template_save' && !$entry;
        die "Template not found.\n" if $action eq 'template_save' && length($id) && !$entry;
        my $raw = $cgi->param('layout_json') // '';
        die "Layout submission is too large.\n" if length($raw) > 200000;
        my $layout = validate_layout($plugin, decode_json($raw));
        $entry ||= { id => $plugin->_new_slide_id([]) };
        $entry->{name} = _name($cgi->param('name'));
        if ($action eq 'template_save') { $entry->{layout} = $layout }
        else {
            $entry->{draft} = $layout;
            if ($action eq 'publish') {
                $entry->{published} = _snapshot($plugin, $layout);
                $entry->{published_name} = $entry->{name};
                ++$entry->{revision};
                $entry->{enabled} = 1;
            }
        }
    } elsif ($action eq 'duplicate' || $action eq 'template_duplicate') {
        die "Entry not found.\n" unless $entry;
        $entry = _copy($entry);
        $entry->{id} = $plugin->_new_slide_id([]);
        $entry->{name} = substr($entry->{name}, 0, 90) . ' (copy)';
        if ($kind eq 'screens') { $entry->{published} = undef; $entry->{enabled} = 0; $entry->{revision} = 0 }
    } elsif ($action eq 'toggle') {
        die "Screen not found.\n" unless $entry;
        my $enabled = ($cgi->param('enabled') // '') eq '1';
        die "Publish this screen before enabling it.\n" if $enabled && !$entry->{published};
        $entry->{enabled} = $enabled ? 1 : 0;
        ++$entry->{revision};
    } elsif ($action eq 'delete' || $action eq 'template_delete') {
        die "Entry not found.\n" unless $entry;
        _remove($plugin, $kind, $entry->{id});
        return '';
    } else { die "Unknown screen action.\n" }
    _put($plugin, $kind, $entry);
    return $entry->{id};
}

sub _json {
    my ($data) = @_;
    my $json = JSON::PP->new->canonical->encode($data);
    $json =~ s/</\\u003c/g; $json =~ s/>/\\u003e/g; $json =~ s/&/\\u0026/g;
    $json =~ s/\x{2028}/\\u2028/g; $json =~ s/\x{2029}/\\u2029/g;
    return $json;
}

sub _file {
    my ($name) = @_;
    (my $directory = File::Spec->rel2abs(__FILE__)) =~ s{/Screens\.pm\z}{};
    open my $fh, '<:encoding(UTF-8)', File::Spec->catfile($directory, $name) or die "Missing signage resource $name.\n";
    local $/; return <$fh>;
}

sub _render {
    my ($name, $data) = @_;
    require Template;
    my $template = Template->new({ ENCODING => 'UTF-8' });
    my $source = _file($name);
    my $html = '';
    $template->process(\$source, $data, \$html) or die "Could not render signage: " . $template->error;
    return $html;
}

sub player_html {
    my ($plugin, $entry, $preview) = @_;
    my $layout = $preview ? _snapshot($plugin, $entry->{draft}) : _copy($entry->{published});
    for my $region (@{$layout->{regions}}) {
        next unless $region->{type} eq 'playlist';
        my @slides;
        for my $slide (@{$region->{slides}}) {
            my $display = _copy($slide);
            $display->{asset_url} = $preview
                ? $plugin->_run_url . '&action=asset&id=' . $slide->{id}
                : '../media/' . $slide->{id} if $slide->{file};
            delete $display->{file};
            push @slides, $display;
        }
        $region->{player_html} = _render('player.tt', {
            slides => \@slides, interval_seconds => $region->{interval_seconds}, fit => $region->{fit}
        });
        delete $region->{slides};
        delete $region->{items};
    }
    return _render('screen-player.tt', {
        boot_json => _json({ name => $preview ? $entry->{name} : ($entry->{published_name} // $entry->{name}), layout => $layout, revision => $entry->{revision},
            revision_url => $preview ? '' : $entry->{id} . '/revision', preview => $preview ? 1 : 0 }),
        player_js => _file('screen-player.js'), player_css => _file('screen-player.css'),
    });
}

sub tool {
    my ($plugin, $preview) = @_;
    my $cgi = $plugin->{cgi};
    my $selected = $cgi->param('id') // '';
    my ($error, $message) = ('', '');
    if (uc($cgi->request_method // 'GET') eq 'POST') {
        if (!$plugin->_valid_csrf) { $error = 'Your session or security token expired. Reload and try again.' }
        elsif ($preview) { $error = 'Preview is read-only.' }
        else {
            eval { $selected = command($plugin); $message = 'Changes saved.'; 1 } or $error = $@;
        }
    }
    if ($preview) {
        my $entry = _entry($plugin, 'screens', $selected);
        unless ($entry) { print $cgi->header(-status => '404 Not Found', -type => 'text/plain'); print 'Screen not found.'; return }
        print $cgi->header(-type => 'text/html', -charset => 'UTF-8', -Cache_Control => 'no-store');
        print encode_utf8(player_html($plugin, $entry, 1));
        return;
    }
    my $index = _index($plugin);
    my @screens = map { my $entry = _entry($plugin, 'screens', $_); +{%$entry, public_url => screen_url($plugin, $_)} } @{$index->{screens}};
    my @templates = map { _entry($plugin, 'templates', $_) } @{$index->{templates}};
    my @media = map {
        +{ id => $_->{id}, media_type => $_->{media_type}, caption => $_->{caption},
            duration_seconds => $_->{duration_seconds}, enabled => $_->{enabled}, usage => usage($plugin, $_->{id}) }
    } @{$plugin->_slides};
    my $boot = { screens => \@screens, templates => \@templates, starters => starters(), media => \@media,
        csrf_token => $plugin->_csrf_token, run_url => $plugin->_run_url, back_url => $plugin->_run_url,
        message => $message, error => $error, selected_id => $selected };
    $boot->{selected_kind} = ($cgi->param('screen_action') // '') =~ /^template_/ ? 'template' : 'screen';
    if ($error && $plugin->_valid_csrf) {
        my $raw = $cgi->param('layout_json') // '';
        if (length($raw) <= 200000) {
            my $submitted = eval { decode_json($raw) };
            if (ref($submitted) eq 'HASH') {
                $boot->{submitted_layout} = $submitted;
                $boot->{submitted_name} = _text($cgi->param('name'), 100);
            }
        }
    }
    print $cgi->header(-type => 'text/html', -charset => 'UTF-8', -Cache_Control => 'no-store');
    print encode_utf8(_render('screens.tt', { boot_json => _json($boot), editor_js => _file('editor.js'),
        editor_css => _file('editor.css'), back_url => $plugin->_run_url }));
}

1;
