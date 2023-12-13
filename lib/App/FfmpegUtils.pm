package App::FfmpegUtils;

use 5.010001;
use strict;
use warnings;
use Log::ger;

use Perinci::Exporter;
use Perinci::Object;

# AUTHORITY
# DATE
# DIST
# VERSION

our %SPEC;

$SPEC{':package'} = {
    v => 1.1,
    summary => 'Utilities related to ffmpeg',
};

our %argspec0_file = (
    file => {
        schema => 'filename*',
        req => 1,
        pos => 0,
    },
);

our %argspec0_files = (
    files => {
        'x.name.is_plural' => 1,
        'x.name.singular' => 'file',
        schema => ['array*' => of => 'filename*'],
        req => 1,
        pos => 0,
        slurpy => 1,
    },
);

our %argspecopt_ffmpeg_path = (
    ffmpeg_path => {
        schema => 'filename*',
    },
);

our %argspecopt_copy = (
    copy => {
        summary => 'Whether to use the "copy" codec (fast but produces inaccurate timings)',
        schema => 'bool*',
    },
);

my @presets = qw/ultrafast superfast veryfast faster fast medium slow slower veryslow/;

sub _nearest {
    sprintf("%d", $_[0]/$_[1]) * $_[1];
}

sub _convert_pct {
    my ($num, $total) = @_;
    if ($num =~ s/%\z//) {
        $num/100 * $total;
    } else {
        $num;
    }
}

$SPEC{reencode_video_with_libx264} = {
    v => 1.1,
    summary => 'Re-encode video (using ffmpeg and libx264)',
    description => <<'_',

This utility runs *ffmpeg* to re-encode your video files using the libx264
codec. It is a wrapper to simplify invocation of ffmpeg. It selects the
appropriate ffmpeg options for you, allows you to specify multiple files, and
picks appropriate output filenames. It also sports a `--dry-run` option to let
you see ffmpeg options to be used without actually running ffmpeg.

This utility is usually used to reduce the file size (and optionally video
width/height) of videos so they are smaller, while minimizing quality loss.
Smartphone-produced videos are often high bitrate (e.g. >10-20Mbit) and not yet
well compressed, so they make a good input for this utility. The default setting
is roughly similar to how Google Photos encodes videos (max 1080p).

The default settings are:

    -v:c libx264
    -preset veryslow (to get the best compression rate, but with the slowest encoding time)
    -crf 28 (0-51, subjectively sane is 18-28, 18 ~ visually lossless, 28 ~ visually acceptable)

when a downsizing is requested (using the `--downsize-to` option), this utility
first checks each input video if it is indeed larger than the requested final
size. If it is, then the `-vf scale` option is added. This utility also
calculates a valid size for ffmpeg, since using `-vf scale=-1:720` sometimes
results in failure due to odd number.

Audio streams are copied, not re-encoded.

Output filenames are:

    ORIGINAL_NAME.crf28.mp4

or (if downsizing is done):

    ORIGINAL_NAME.480p-crf28.mp4

_
    args => {
        %argspec0_files,
        %argspecopt_ffmpeg_path,
        crf => {
            schema => ['int*', between=>[0,51]],
        },
        scale => {
            schema => 'str*',
            default => '1080^>',
            description => <<'_',

Scale video to specified size. See <pm:Math::Image::CalcResized> or
<prog:calc-image-resized-size> for more details on scale specification. Some
examples include:

The default is `1080^>` which means to shrink to 1080p if video size is larger
than 1080p.

To disable scaling, set `--scale` to '' (empty string), or specify
`--dont-scale` on the CLI.

_
            cmdline_aliases => {
                dont_scale => {summary=>"Alias for --scale ''", is_flag=>1, code=>sub {$_[0]{scale} = ''}},
                no_scale   => {summary=>"Alias for --scale ''", is_flag=>1, code=>sub {$_[0]{scale} = ''}},
            },
        },
        preset => {
            schema => ['str*', in=>\@presets],
            default => 'veryslow',
            cmdline_aliases => {
                (map {($_ => {is_flag=>1, summary=>"Shortcut for --preset=$_", code=>do { my $p = $_; sub { $_[0]{preset} = $p }}})} @presets),
            },
        },
        frame_rate => {
            summary => 'Set frame rate, in fps',
            schema => 'ufloat*',
            cmdline_aliases => {r=>{}},
        },
        audio_sample_rate => {
            summary => 'Set audio sample rate, in Hz',
            schema => 'uint*',
            cmdline_aliases => {sample_rate=>{}},
        },
    },
    features => {
        dry_run => 1,
    },
    examples => [
        {
            summary => 'The default setting is to shrink to 1080p if video is larger than 1080p',
            src => '[[prog]] *',
            src_plang => 'bash',
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'Do not scale/shrink',
            src => '[[prog]] --dont-scale *',
            src_plang => 'bash',
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'Shrink to 480p if video is larger than 480p, but make the reencoding "visually lossless"',
            src => "[[prog]] --scale '480^>' --crf 18 *",
            src_plang => 'bash',
            test => 0,
            'x.doc.show_result' => 0,
        },
    ],
};
sub reencode_video_with_libx264 {
    require File::Which;
    require IPC::System::Options;
    require Media::Info;

    my %args = @_;

    my $ffmpeg_path = $args{ffmpeg_path} // File::Which::which("ffmpeg");
    my $scale = $args{scale};

    unless ($args{-dry_run}) {
        return [400, "Cannot find ffmpeg in path"] unless defined $ffmpeg_path;
        return [400, "ffmpeg path $ffmpeg_path is not executable"] unless -f $ffmpeg_path;
    }

    for my $file (@{$args{files}}) {
        log_info "Processing file %s ...", $file;

        unless (-f $file) {
            log_error "No such file %s, skipped", $file;
            next;
        }

        my $res = Media::Info::get_media_info(media => $file);
        unless ($res->[0] == 200) {
            log_error "Can't get media information fod %s: %s - %s, skipped",
                $file, $res->[0], $res->[1];
            next;
        }
        my $video_info = $res->[2];

        my $crf = $args{crf} // 28;
        my @ffmpeg_args = (
            "-i", $file,
        );

        my $scale_suffix;
      SCALE: {
            last unless defined $scale && length $scale;
            require Math::Image::CalcResized;
            my $calcres = Math::Image::CalcResized::calc_image_resized_size(
                size => "$video_info->{video_width}x$video_info->{video_height}",
                resize => $scale,
            );
            return [400, "Can't scale using '$scale': $calcres->[0] - $calcres->[1]"]
                unless $calcres->[0] == 200;

            my ($scaled_width, $scaled_height) = $calcres->[2] =~ /(.+)x(.+)/
                or return [500, "calc_image_resized_size() doesn't return new WxH ($calcres->[2])"];
            last unless $scaled_width != $video_info->{video_width} ||
                $scaled_height != $video_info->{video_height};
            ($scale_suffix = $calcres->[3]{'func.human_specific'}) =~ s/\W+/_/g;
            push @ffmpeg_args, "-vf", sprintf(
                "scale=%d:%d",
                _nearest($scaled_width, 2),  # make sure divisible by 2 (optimum is divisible by 16, then 8, then 4)
                _nearest($scaled_height, 2),
            );
        } # SCALE

        my $output_file = $file;
        my $ext = $scale_suffix ? ".$scale_suffix-crf$crf.mp4" : ".crf$crf.mp4";
        $output_file =~ s/(\.\w{3,4})?\z/($1 eq ".mp4" ? "" : $1) . $ext/e;

        my $audio_is_copy = 1;
        $audio_is_copy = 0 if defined $args{audio_sample_rate};

        push @ffmpeg_args, (
            "-c:v", "libx264",
            "-crf", $crf,
            "-preset", ($args{preset} // 'veryslow'),
            (defined $args{frame_rate} ? ("-r", $args{frame_rate}) : ()),
            "-c:a", ($audio_is_copy ? "copy" : "aac"),
            (defined $args{audio_sample_rate} ? ("-ar", $args{audio_sample_rate}) : ()),
            $output_file,
        );

        if ($args{-dry_run}) {
            log_info "[DRY-RUN] Running $ffmpeg_path with args %s ...", \@ffmpeg_args;
            next;
        }

        IPC::System::Options::system(
            {log=>1},
            $ffmpeg_path, @ffmpeg_args,
        );
        if ($?) {
            my ($exit_code, $signal, $core_dump) = ($? < 0 ? $? : $? >> 8, $? & 127, $? & 128);
            log_error "ffmpeg for $file failed: exit_code=$exit_code, signal=$signal, core_dump=$core_dump";
        }
    }

    [200];
}

$SPEC{split_video_by_duration} = {
    v => 1.1,
    summary => 'Split video by duration into parts',
    description => <<'_',

This utility uses **ffmpeg** (particularly the `-t` and `-ss`) option to split a
longer video into shorter videos. For example, if you have `long.mp4` with
duration of 1h12m and you run it through this utility with `--every 15min` then
you will have 5 new video files: `long.1of5.mp4` (15min), `long.2of5.mp4`
(15min), `long.3of5.mp4` (15min), `long.4of5.mp4` (15min), and `long.5of5.mp4`
(12min).

Compared to using `ffmpeg` directly, this wrapper offers convenience of
calculating the times (`-ss`) option for you, handling multiple files,
automatically choosing output filename, and tab completion.

_
    args => {
        %argspec0_files,
        # XXX start => {},
        every => {
            schema => ['any*', of=>['duration*', 'percent_str*']],
        },
        parts => {
            schema => 'posint*',
        },
        %argspecopt_copy,
        # XXX merge_if_last_part_is_shorter_than => {},
        # XXX output_filename_pattern
    },
    args_rels => {
        req_one => [qw/every parts/],
    },
    examples => [
        {
            summary => 'Split video per 15 minutes',
            src_plang => 'bash',
            src => '[[prog]] --every 15min foo.mp4',
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'Split video per 30s for WhatsApp status',
            src_plang => 'bash',
            src => '[[prog]] foo.mp4 30s',
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'Split video into 4 equiduration parts',
            src_plang => 'bash',
            src => '[[prog]] foo.mp4 --parts 4',
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'Another way to split into equiduration parts using percentage in --every',
            src_plang => 'bash',
            src => '[[prog]] foo.mp4 --every 25%',
            test => 0,
            'x.doc.show_result' => 0,
        },
    ],
    features => {
        dry_run => 1,
    },
    deps => {
        prog => "ffmpeg", # XXX allow FFMPEG_PATH
    },
    links => [
        {url=>'prog:srtsplit', summary=>'Split .srt by duration, much like this utility'},
    ],
};
sub split_video_by_duration {
    require POSIX;

    my %args = @_;
    my $files = $args{files};
    my $every = $args{every};
    my $parts = $args{parts};

    my $envres = envresmulti();
    my $j = -1;
    for my $file (@$files) {

        $j++;
        log_info "Processing file %s ...", $file;

        require Media::Info;
        my $res = Media::Info::get_media_info(media => $file);
        unless ($res->[0] == 200) {
            $envres->add_result($res->[0], "Can't get info for video $file: $res->[1]", {item_id=>$j});
            next;
        }

        my $total_dur = $res->[2]{duration};
        unless ($total_dur) {
            $envres->add_result(412, "Duration of video $file is zero", {item_id=>$j});
            next;
        }

        my $part_dur;
        if (defined $parts) {
            return [400, "Please specify a positive number in --parts"] unless $parts >= 1;
            $part_dur = $total_dur / $parts;
        } elsif (defined $every) {
            if ($every =~ s/%\z//) {
                $every > 0 && $every <= 100 or return [400, "For percentage in --every, please specify a number between 0 and 100"];
                $part_dur = $total_dur * ($every/100);
            } else {
                $every > 0 or return [400, "Please specify a positive number in --every"];
                $part_dur = $every;
            }
        } else {
            return [400, "Please specify either --every or --parts"];
        }

        my $num_parts = POSIX::ceil($total_dur / $part_dur);
        my $fmt = $num_parts >= 1000 ? "%04d" : $num_parts >= 100 ? "%03d" : $num_parts >= 10 ? "%02d" : "%d";

        unless ($num_parts >= 2) {
            $envres->add_result(304, "No split necessary for video $file", {item_id=>$j});
            next;
        }

        require IPC::System::Options;
        for my $i (1..$num_parts) {
            my $part_label = sprintf "${fmt}of%d", $i, $num_parts;
            my $ofile = $file;
            if ($ofile =~ /\.\w+\z/) { $ofile =~ s/(\.\w+)\z/.$part_label$1/ } else { $ofile .= ".$part_label" }
            my $time_start = ($i-1)*$part_dur;
            IPC::System::Options::system(
                {log=>1, dry_run=>$args{-dry_run}},
                "ffmpeg", "-i", $file, ($args{copy} ? ("-c", "copy") : ()), "-ss", $time_start, "-t", $part_dur, $ofile);
            my ($exit_code, $signal, $core_dump) = ($? < 0 ? $? : $? >> 8, $? & 127, $? & 128);
            if ($exit_code) {
                $envres->add_result(500, "ffmpeg exited $exit_code (sig $signal) for video $file: $!", {item_id=>$j});
            } else {
                $envres->add_result(200, "Video $file successfully split", {item_id=>$j});
            }
        }

    } # for $file

    $envres->as_struct;
}

$SPEC{cut_video_by_duration} = {
    v => 1.1,
    summary => 'Get a portion (time range) of a video',
    description => <<'_',

This utility uses *ffmpeg* (particularly the `-t` and `-ss`) option to get a
portion (time range) of a video.

Compared to using `ffmpeg` directly, this wrapper offers convenience of more
flexibility in specifying times and duration (e.g. '15s' as well as '00:10' as
well as 'PT1M30S'), specifying only 'end' and 'duration', handling multiple
files, automatically choosing output filename, and tab completion.

_
    args => {
        %argspec0_files,
        start => {
            schema => ['any*', of=>['duration*', 'percent_str*']],
            cmdline_aliases => {s=>{}},
        },
        end => {
            schema => ['any*', of=>['duration*', 'percent_str*']],
            cmdline_aliases => {e=>{}},
        },
        duration => {
            schema => ['any*', of=>['duration*', 'percent_str*']],
            cmdline_aliases => {d=>{}},
        },
        %argspecopt_copy,
    },
    args_rels => {
        req_one => [qw/start duration/],
    },
    examples => [
        {
            summary => 'Specify start only, the result is 100s.cut_40_to_100.mp4',
            argv => ['100s.mp4', '-s', '40s'],
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'Specify duration only (using percentage) of two files, the results are 100s.cut_0_to_30.mp4 & 50s.cut_0_to_15.mp4',
            argv => ['100s.mp4', '50s.mp4', '-d', '30%'],
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'Specify end only (using h:m:s notation), the result is 100s.cut_0_to_63.mp4',
            argv => ['100s.mp4', '-e', '00:01:03'],
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'Specify start & end only (using h:m:s notation), the result is 100s.cut_50_to_63.mp4',
            argv => ['100s.mp4', '-s', '00:00:50', '-e', '00:01:03'],
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'Specify start & duration only (using seconds), the result is 100s.cut_50_to_63.mp4',
            argv => ['100s.mp4', '-s', '50', '-d', '13'],
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'Specify end & duration only (using human & ISO 8601 notation), the result is 100s.cut_50_to_63.mp4',
            argv => ['100s.mp4', '-e', 'PT63S', '-d', '13s'],
            test => 0,
            'x.doc.show_result' => 0,
        },
    ],
    features => {
        dry_run => 1,
    },
    deps => {
        prog => "ffmpeg", # XXX allow FFMPEG_PATH
    },
    links => [
    ],
};
sub cut_video_by_duration {
    require POSIX;

    my %args = @_;
    my $files = $args{files};
    my $start0    = $args{start};
    my $end0      = $args{end};
    my $duration0 = $args{duration};

    my $envres = envresmulti();
    my $j = -1;
    for my $file (@$files) {
        $j++;
        require Media::Info;
        my $res = Media::Info::get_media_info(media => $file);
        unless ($res->[0] == 200) {
            $envres->add_result($res->[0], "Can't get media info for video '$file': $res->[1], skipped", {item_id=>$j});
            next;
        }

        my $total_dur = $res->[2]{duration}
            or do {
                $envres->add_result(412, "Duration of video '$file' is zero, skipped", {item_id=>$j});
                next;
            };

        my ($start, $end, $duration);
        if (defined $start0 && !defined $end0 && !defined $duration0) {
            $start    = _convert_pct($start0, $total_dur);
            $end      = $total_dur;
            $duration = $end - $start;
        } elsif (!defined $start0 && defined $end0 && !defined $duration0) {
            $start    = 0;
            $end      = _convert_pct($end0, $total_dur);
            $duration = $end - $start;
        } elsif (!defined $start0 && !defined $end0 && defined $duration0) {
            $start    = 0;
            $end      = _convert_pct($duration0, $total_dur);
            $duration = $duration0;
        } elsif (defined $start0 && defined $end0 && !defined $duration0) {
            $start    = _convert_pct($start0, $total_dur);
            $end      = _convert_pct($end0, $total_dur);
            $duration = $end - $start;
        } elsif (defined $start0 && !defined $end0 && defined $duration0) {
            $start    = _convert_pct($start0, $total_dur);
            $duration = _convert_pct($duration0, $total_dur);
            $end      = $start + $duration;
        } elsif (!defined $start0 && defined $end0 && defined $duration0) {
            $end      = _convert_pct($end0, $total_dur);
            $duration = _convert_pct($duration0, $total_dur);
            $start    = $end - $duration;
        } elsif (defined $start0 && defined $end0 && !defined $duration0) {
            $start    = _convert_pct($start0, $total_dur);
            $end      = _convert_pct($end0, $total_dur);
            $duration = $end - $start;
        } elsif (defined $start0 && defined $end0 && defined $duration0) {
            return [409, "Please only specify 'start' & 'end', 'start' & 'duration', or 'end' & 'duration', not all three"];
        } else {
            return [500, "Internal bug"];
        }

        do { $envres->add_result(400, "Start time ($start) for video '$file' is negative, skipped", {item_id=>$j}); next }   if $start < 0;
        do { $envres->add_result(400, "End time ($end) for video '$file' is negative, skipped", {item_id=>$j}); next }       if $end < 0;
        do { $envres->add_result(400, "Non-positive duration ($duration) for video '$file', skipped", {item_id=>$j}); next } if $duration <= 0;
        do { $envres->add_result(400, "Start time ($start) is larger than end time ($end) for video '$file', skipped", {item_id=>$j}); next } if $end < $start;
        do { $envres->add_result(400, "Start time ($start) exceeds the total duration of video for video '$file', skipped", {item_id=>$j}); next }  if $start > $total_dur;
        do { $envres->add_result(400, "End time ($end) exceeds the total duration of video for video '$file', skipped", {item_id=>$j}); next }      if $start > $total_dur;
        do { $envres->add_result(400, "Duration ($duration) exceeds the total duration of video for video '$file', skipped", {item_id=>$j}); next } if $duration > $total_dur;

        if ($start == 0 && $end == $total_dur) {
            $envres->add_result(304, "No cutting necessary for video '$file' (whole length requested), skipped", {item_id=>$j});
            next;
        }

        log_trace "Video %s, start=%s, duration=%s, end=%s", $file, $start, $duration, $end;
        require IPC::System::Options;
        my $label = sprintf 'cut_%s_to_%s', $start, $end;
        my $ofile = $file;
        if ($ofile =~ /\.\w+\z/) { $ofile =~ s/(\.\w+)\z/.$label$1/ } else { $ofile .= ".$label" }
        IPC::System::Options::system(
            {log=>1, dry_run=>$args{-dry_run}},
            "ffmpeg", "-i", $file, ($args{copy} ? ("-c", "copy") : ()), "-ss", $start, "-t", $duration, $ofile);
        my ($exit_code, $signal, $core_dump) = ($? < 0 ? $? : $? >> 8, $? & 127, $? & 128);
        if ($exit_code) {
            $envres->add_result(500, "ffmpeg exited $exit_code (sig $signal) for video $file: $!", {item_id=>$j});
        } else {
            $envres->add_result(200, "Video '$file' successfully cut", {item_id=>$j});
        }

    } # for $file

    $envres->as_struct;
}

1;
# ABSTRACT:
