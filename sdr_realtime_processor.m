function sdr_realtime_processor()
% SDR实时信号接收与解调系统
% 功能: 从IQ基带文件逐帧读取数据, 完成AM/FM信号的实时流式解调
% 数据源: IQ WAV文件回放 (v1), RTL-SDR硬件
% 输出: 实时频谱, 瀑布图, 音频波形, 低延迟音频播放

    %% ==================== 全局状态 ====================
    state = struct();
    % --- 数据源 ---
    state.source_type      = 'file';
    state.source_fid       = -1;
    state.source_filepath  = '';
    state.source_data_len  = 0;
    state.source_read_pos  = 0;
    state.source_fs        = 2.4e6;
    state.source_fc        = 96.5e6;
    state.source_gain      = 40;
    state.source_handle    = [];      % RTL-SDR 对象句柄
    state.source_file_info = '';
    % --- 处理参数 ---
    state.running          = false;
    state.mode             = 'FM';
    state.f_offset         = 0;
    state.frame_size       = 65536;
    state.audio_fs         = 48000;
    state.loop_playback    = false;
    state.use_audio_toolbox = false;
    state.audio_accum      = [];       % 流式累积 (用于导出)
    state.audio            = [];       % 最终音频 (处理完成后赋值)
    state.is_demod         = false;    % 是否有可播放/导出的音频
    % --- 频道选择滤波器 ---
    state.cs_b_fm          = [];
    state.cs_b_am          = [];
    state.cs_zi            = [];
    % --- DDC混频表缓存 (避免每帧重算exp) ---
    state.ddc_table        = [];
    state.ddc_table_offset = nan;
    state.ddc_table_N      = 0;
    % --- AM解调状态 ---
    state.am_dc_alpha      = 0.999;
    state.am_dc_est        = 0;
    state.am_decim_stages  = [];
    % --- FM解调状态 ---
    state.fm_dc_alpha      = 0.9999;
    state.fm_dc_est        = 0;
    state.fm_decim_stages  = [];
    state.fm_last_iq       = complex(NaN);
    state.fm_deemp_b       = [];
    state.fm_deemp_a       = [];
    state.fm_deemp_zi      = [];
    % --- 音频输出 ---
    state.audio_writer     = [];
    % --- 显示缓冲 ---
    state.waterfall_buf    = [];
    state.waterfall_freq   = [];
    state.waterfall_max    = 150;
    state.waterfall_idx    = 1;
    state.audio_buf        = [];
    state.audio_buf_idx    = 1;
    state.spectrum_line    = [];
    state.waterfall_img    = [];
    state.audio_line       = [];
    % --- 性能统计 ---
    state.frame_count      = 0;
    state.frame_times      = [];
    state.ft_idx           = 1;
    state.total_overruns   = 0;
    state.t_start          = [];
    % --- 性能日志 (自动记录, 含GUI开销) ---
    state.perf_log_file    = '';
    state.perf_log_fid     = -1;  % 保持打开, 避免重复fopen/fclose开销
    state.perf_last_snap   = -inf;
    % --- GUI句柄 ---
    state.fig              = [];
    state.dd_source        = [];
    state.btn_browse       = [];
    state.lbl_file         = [];
    state.gain_row         = [];
    state.edit_fs          = [];
    state.edit_fc          = [];
    state.edit_gain        = [];
    state.edit_fo          = [];
    state.rb_fm            = [];
    state.rb_am            = [];
    state.mode_group       = [];
    state.dd_frame         = [];
    state.cb_loop          = [];
    state.btn_start        = [];
    state.btn_play         = [];
    state.btn_export       = [];
    state.txt_status       = [];
    state.ax_spectrum      = [];
    state.ax_waterfall     = [];
    state.ax_audio         = [];
    state.lbl_status       = [];
    state.lbl_perf         = [];
    state.lbl_mode         = [];


    %% ==================== GUI 构建 ====================
    old_figs = findall(0, 'Type', 'figure', 'Tag', 'SdrRealtimeProcessor');
    if ~isempty(old_figs)
        close(old_figs);
    end

    fig = uifigure('Name', 'SDR 实时接收与解调系统', ...
                   'Position', [100, 40, 1200, 760], ...
                   'Resize', 'on', ...
                   'Tag', 'SdrRealtimeProcessor', ...
                   'Color', [0.94 0.94 0.94], ...
                   'CloseRequestFcn', @(src, evt) close_callback());
    state.fig = fig;

    % ---- 主布局 ----
    main_grid = uigridlayout(fig, [2, 1]);
    main_grid.RowHeight = {'1x', 32};
    main_grid.Padding = [8, 8, 8, 4];
    main_grid.RowSpacing = 6;

    % ---- 上半部分: 控制面板 + 显示区域 ----
    top_grid = uigridlayout(main_grid, [1, 2]);
    top_grid.ColumnWidth = {260, '1x'};
    top_grid.Padding = [0, 0, 0, 0];
    top_grid.ColumnSpacing = 8;

    % ---- 左侧控制面板 ----
    ctrl_panel = uipanel(top_grid, 'Title', '实时控制', ...
                         'FontSize', 13, 'FontWeight', 'bold');

    ctrl_grid = uigridlayout(ctrl_panel, [17, 1]);
    ctrl_grid.RowHeight = {22, 30, 36, 22, 36, 36, 36, 36, 22, 50, 36, 28, 44, 36, 36, 22, '1x'};
    ctrl_grid.Padding = [8, 8, 8, 8];
    ctrl_grid.RowSpacing = 4;

    % --- 数据源区 ---
    uilabel(ctrl_grid, 'Text', '━━ 数据源 ━━', ...
            'FontWeight', 'bold', 'HorizontalAlignment', 'center');

    state.dd_source = uidropdown(ctrl_grid, ...
        'Items', {'文件回放', 'RTL-SDR 硬件'}, ...
        'Value', '文件回放', ...
        'ValueChangedFcn', @(src, evt) source_changed_callback());

    browse_row = uigridlayout(ctrl_grid, [1, 2]);
    browse_row.ColumnWidth = {90, '1x'};
    browse_row.Padding = [2, 0, 2, 0];
    browse_row.RowSpacing = 0;
    state.btn_browse = uibutton(browse_row, 'push', ...
        'Text', '选择IQ文件...', ...
        'ButtonPushedFcn', @(src, evt) browse_callback(), ...
        'FontSize', 11);
    state.lbl_file = uilabel(browse_row, 'Text', '未选择', ...
        'FontColor', [0.5 0.5 0.5], 'VerticalAlignment', 'center');

    % --- 射频参数区 ---
    uilabel(ctrl_grid, 'Text', '━━ 射频参数 ━━', ...
            'FontWeight', 'bold', 'HorizontalAlignment', 'center');

    fs_row = uigridlayout(ctrl_grid, [1, 2]);
    fs_row.ColumnWidth = {65, '1x'};
    fs_row.Padding = [2, 0, 2, 0];
    uilabel(fs_row, 'Text', '采样率:');
    state.edit_fs = uieditfield(fs_row, 'numeric', ...
        'Value', 2.4, 'ValueDisplayFormat', '%.3f MSPS', ...
        'Editable', 'off', 'Tooltip', '从文件自动读取, 不可编辑');

    fc_row = uigridlayout(ctrl_grid, [1, 2]);
    fc_row.ColumnWidth = {65, '1x'};
    fc_row.Padding = [2, 0, 2, 0];
    uilabel(fc_row, 'Text', '中心频率:');
    state.edit_fc = uieditfield(fc_row, 'numeric', ...
        'Value', 96.5, 'ValueDisplayFormat', '%.3f MHz', ...
        'Tooltip', 'RTL-SDR接收中心频率 / 记录时的SDR#中心频率');

    % RF增益 (仅RTL-SDR模式可见)
    gain_row = uigridlayout(ctrl_grid, [1, 2]);
    gain_row.ColumnWidth = {65, '1x'};
    gain_row.Padding = [2, 0, 2, 0];
    state.gain_row = gain_row;  % 保存句柄以控制可见性
    uilabel(gain_row, 'Text', 'RF增益:');
    state.edit_gain = uieditfield(gain_row, 'numeric', ...
        'Value', 40, 'ValueDisplayFormat', '%.0f dB', ...
        'Tooltip', 'RTL-SDR射频增益 (0~49.6 dB)');
    gain_row.Visible = 'off';  % 默认隐藏 (文件回放模式)

    fo_row = uigridlayout(ctrl_grid, [1, 2]);
    fo_row.ColumnWidth = {65, '1x'};
    fo_row.Padding = [2, 0, 2, 0];
    uilabel(fo_row, 'Text', '解调偏移:');
    state.edit_fo = uieditfield(fo_row, 'numeric', ...
        'Value', 0, 'ValueDisplayFormat', '%.1f kHz', ...
        'Tooltip', '目标信号在基带中的频率偏移, 看频谱峰值确定后填入');

    % --- 解调设置区 ---
    uilabel(ctrl_grid, 'Text', '━━ 解调设置 ━━', ...
            'FontWeight', 'bold', 'HorizontalAlignment', 'center');

    state.mode_group = uibuttongroup(ctrl_grid);
    state.rb_fm = uiradiobutton(state.mode_group, 'Text', 'FM 宽带解调', ...
        'Value', 1, 'Position', [8, 10, 120, 22]);
    state.rb_am = uiradiobutton(state.mode_group, 'Text', 'AM 解调', ...
        'Position', [140, 10, 90, 22]);
    state.mode_group.SelectionChangedFcn = @(src, evt) mode_changed_callback();

    frame_row = uigridlayout(ctrl_grid, [1, 2]);
    frame_row.ColumnWidth = {65, '1x'};
    frame_row.Padding = [2, 0, 2, 0];
    uilabel(frame_row, 'Text', '帧大小:');
    state.dd_frame = uidropdown(frame_row, ...
        'Items', {'16384', '32768', '65536', '131072'}, ...
        'Value', '65536', ...
        'Tooltip', '每帧IQ样点数。越小: 延迟低但CPU开销大; 越大: 效率高但延迟大');

    state.cb_loop = uicheckbox(ctrl_grid, 'Text', '循环播放', ...
        'Value', false);

    state.btn_start = uibutton(ctrl_grid, 'push', ...
        'Text', '▶ 开始处理', ...
        'ButtonPushedFcn', @(src, evt) start_stop_callback(), ...
        'FontWeight', 'bold', 'FontSize', 13, ...
        'BackgroundColor', [0.6 1.0 0.6]);

    state.btn_play = uibutton(ctrl_grid, 'push', ...
        'Text', '🔊 播放音频', ...
        'ButtonPushedFcn', @(src, evt) play_callback(), ...
        'Enable', 'off');

    state.btn_export = uibutton(ctrl_grid, 'push', ...
        'Text', '💾 导出WAV', ...
        'ButtonPushedFcn', @(src, evt) export_callback(), ...
        'Enable', 'off');

    % --- 状态文本区 ---
    uilabel(ctrl_grid, 'Text', '━━ 状态 ━━', ...
            'FontWeight', 'bold', 'HorizontalAlignment', 'center');
    state.txt_status = uitextarea(ctrl_grid, ...
        'Value', {'帧率: -- fps', '处理时间: -- ms/帧', ...
                  '音频欠载: 0 次', '已处理: 0 帧', '总运行: 00:00'}, ...
        'Editable', 'off', ...
        'FontSize', 10, ...
        'FontName', 'Consolas');

    % ---- 右侧显示区域 ----
    right_panel = uipanel(top_grid, 'Title', '实时分析', ...
                          'FontSize', 13, 'FontWeight', 'bold');

    tab_group = uitabgroup(right_panel);

    % Tab 1: 频谱与瀑布图
    tab_spec = uitab(tab_group, 'Title', '频谱与瀑布图');
    spec_grid = uigridlayout(tab_spec, [2, 1]);
    spec_grid.RowHeight = {'3x', '2x'};

    state.ax_spectrum = uiaxes(spec_grid);
    title(state.ax_spectrum, '实时频谱 (FFT)');
    xlabel(state.ax_spectrum, '频率 (kHz)');
    ylabel(state.ax_spectrum, '功率 (dB)');
    grid(state.ax_spectrum, 'on');
    state.ax_spectrum.Box = 'on';
    state.ax_spectrum.NextPlot = 'replacechildren';

    state.ax_waterfall = uiaxes(spec_grid);
    title(state.ax_waterfall, '实时瀑布图');
    xlabel(state.ax_waterfall, '频率 (kHz)');
    ylabel(state.ax_waterfall, '帧序号 (最新在上)');
    grid(state.ax_waterfall, 'on');
    state.ax_waterfall.Box = 'on';
    state.ax_waterfall.NextPlot = 'replacechildren';

    % Tab 2: 音频波形
    tab_time = uitab(tab_group, 'Title', '音频波形');
    time_grid = uigridlayout(tab_time, [1, 1]);
    time_grid.Padding = [4, 4, 4, 4];

    state.ax_audio = uiaxes(time_grid);
    title(state.ax_audio, '实时音频波形 (最近2秒)');
    xlabel(state.ax_audio, '时间 (s)');
    ylabel(state.ax_audio, '归一化幅度');
    grid(state.ax_audio, 'on');
    state.ax_audio.Box = 'on';
    state.ax_audio.NextPlot = 'replacechildren';

    % ---- 状态栏 ----
    bottom_grid = uigridlayout(main_grid, [1, 3]);
    bottom_grid.ColumnWidth = {'1x', 220, 180};
    bottom_grid.Padding = [6, 0, 6, 2];

    state.lbl_status = uilabel(bottom_grid, ...
        'Text', '就绪 - 请选择IQ基带数据文件', ...
        'FontColor', [0.2 0.2 0.2]);

    state.lbl_perf = uilabel(bottom_grid, ...
        'Text', '帧率: -- | 延迟: -- ms', ...
        'HorizontalAlignment', 'right', ...
        'FontColor', [0.3 0.3 0.3]);

    state.lbl_mode = uilabel(bottom_grid, ...
        'Text', '模式: FM解调', ...
        'HorizontalAlignment', 'right', ...
        'FontWeight', 'bold', 'FontColor', [0.2 0.4 0.8]);

    % 检测音频工具箱
    try
        aw = audioDeviceWriter('SampleRate', 48000);
        release(aw);
        state.use_audio_toolbox = true;
    catch
        state.use_audio_toolbox = false;
    end

    %% ==================== 回调函数 ====================

    function browse_callback()
        [fname, fpath] = uigetfile({'*.wav;*.iq;*.bin', ...
            'IQ基带数据文件 (*.wav, *.iq, *.bin)'; ...
            '*.*', '所有文件 (*.*)'}, '选择IQ基带数据文件');

        if fname == 0
            return;
        end

        fullpath = fullfile(fpath, fname);
        state.source_filepath = fullpath;

        % 获取文件信息
        try
            info = audioinfo(fullpath);
            state.source_fs = info.SampleRate;
            state.source_data_len = info.TotalSamples;
            state.source_file_info = sprintf('%s | %.1f MHz | %.1f MSPS | %d通道 | %.1fs', ...
                info.Filename, info.SampleRate/1e6, info.SampleRate/1e6, ...
                info.NumChannels, info.Duration);
        catch
            % audioinfo失败, 尝试audioread小片段
            try
                [~, fs_read] = audioread(fullpath, [1, 1000]);
                state.source_fs = fs_read;
                finfo = dir(fullpath);
                state.source_data_len = floor(finfo.bytes / 4);
                state.source_file_info = sprintf('%s | %.1f MB | ~%.1fs', ...
                    fname, finfo.bytes/1e6, state.source_data_len/fs_read);
            catch ME
                state.lbl_status.Text = ['无法读取文件: ', ME.message];
                state.lbl_status.FontColor = [0.8 0 0];
                return;
            end
        end

        [~, name, ext] = fileparts(fullpath);
        short_name = [name, ext];
        if length(short_name) > 28
            short_name = ['...', short_name(end-24:end)];
        end
        state.lbl_file.Text = short_name;
        state.edit_fs.Value = state.source_fs / 1e6;
        state.lbl_status.Text = ['文件就绪: ', short_name];
        state.lbl_status.FontColor = [0 0.6 0];
        state.lbl_mode.Text = ['模式: ', state.mode, '解调'];

        % 显示频谱预览 (方便在开始前设置解调偏移)
        quick_spectrum_preview();
    end

    function quick_spectrum_preview()
        % 快速读取文件片段显示频谱, 方便用户设置解调偏移
        fc = state.edit_fc.Value * 1e6;
        try
            n_preview = min(state.source_data_len, round(state.source_fs * 5));
            data = audioread(state.source_filepath, [1, n_preview], 'native');
            iq_preview = double(data(:,1)) + 1j*double(data(:,2));
        catch
            return;
        end

        [pxx, f] = pwelch(iq_preview, hann(4096), 2048, 8192, state.source_fs);
        pxx_db = fftshift(10 * log10(pxx));
        f_centered = f - state.source_fs/2;

        ax = state.ax_spectrum;
        cla(ax);
        plot(ax, f_centered/1e3, pxx_db, 'b-', 'LineWidth', 1.0);
        hold(ax, 'on');

        % 带宽参考线
        xline(ax, -100, '--', 'Color', [0.1 0.4 1.0], 'LineWidth', 1.2);
        xline(ax, +100, '--', 'Color', [0.1 0.4 1.0], 'LineWidth', 1.2);

        % 信号检测标注
        try
            signals = detect_signals(f_centered, pxx_db, state.mode);
            colors = lines(min(length(signals), 7));
            for k = 1:length(signals)
                s = signals(k);
                c = colors(k, :);
                xline(ax, s.freq/1e3, '-', 'Color', c, 'LineWidth', 1.5);
                text(ax, s.freq/1e3, s.peak_pwr+2, sprintf('%.1f kHz', s.freq/1e3), ...
                    'Color', c, 'FontSize', 9, 'FontWeight', 'bold', ...
                    'HorizontalAlignment', 'center');
            end
        catch
        end

        hold(ax, 'off');
        xlabel(ax, '频率 (kHz)');
        ylabel(ax, '功率谱密度 (dB/Hz)');
        title(ax, sprintf('频谱预览 (%s, Fc=%.3f MHz)', state.mode, fc/1e6));
        grid(ax, 'on');
        set_spectrum_range(ax);
        state.spectrum_line = [];

        % 同步更新瀑布图预览
        ax_wf = state.ax_waterfall;
        cla(ax_wf);
        try
            n_segs = min(200, floor(length(iq_preview) / 4096));
            spec = zeros(8192, n_segs);
            win = hann(4096);
            for i = 1:n_segs
                si = (i-1) * 4096 + 1;
                seg = iq_preview(si:min(si+4095, end));
                if length(seg) < 4096
                    seg_w = [seg; zeros(4096-length(seg),1)] .* win;
                else
                    seg_w = seg .* win;
                end
                spec(:, i) = fft(seg_w, 8192);
            end
            p_db = fftshift(10*log10(abs(spec).^2 + eps), 1);
            f_khz = ((0:8191)'/8192 * state.source_fs - state.source_fs/2) / 1e3;
            imagesc(ax_wf, f_khz, 1:n_segs, p_db');
            set(ax_wf, 'YDir', 'reverse');
            try colormap(ax_wf, 'turbo'); catch; end
            set(ax_wf, 'Color', [0.02 0.02 0.08]);
            colorbar(ax_wf);
            xlabel(ax_wf, '频率 (kHz)');
            title(ax_wf, sprintf('瀑布图预览 (Fc=%.3f MHz)', fc/1e6));
        catch
            text(ax_wf, 0.5, 0.5, '瀑布图预览失败', ...
                'HorizontalAlignment', 'center');
        end
        state.waterfall_img = [];
    end

    function source_changed_callback()
        sel = state.dd_source.Value;
        switch sel
            case '文件回放'
                state.source_type = 'file';
                state.btn_browse.Visible = 'on';
                state.lbl_file.Visible = 'on';
                state.btn_browse.Enable = 'on';
                state.cb_loop.Enable = 'on';
                state.edit_fs.Editable = 'off';
                state.gain_row.Visible = 'off';
                state.lbl_status.Text = '文件回放模式 - 请选择IQ基带数据文件';
                state.lbl_status.FontColor = [0.2 0.2 0.2];
            case 'RTL-SDR 硬件'
                state.source_type = 'rtlsdr';
                state.btn_browse.Visible = 'off';
                state.lbl_file.Visible = 'off';
                state.cb_loop.Enable = 'off';
                state.edit_fs.Editable = 'on';
                state.edit_fs.Value = 2.4;
                state.gain_row.Visible = 'on';
                % 检测支持包是否已安装
                if exist('comm.SDRRTLReceiver', 'class')
                    state.lbl_status.Text = 'RTL-SDR 已就绪 - 可开始实时接收';
                    state.lbl_status.FontColor = [0 0.6 0];
                else
                    state.lbl_status.Text = '请先安装 RTL-SDR 支持包: 运行 supportPackageInstaller';
                    state.lbl_status.FontColor = [0.8 0.4 0];
                end
        end
    end

    function mode_changed_callback()
        prev_mode = state.mode;
        if state.rb_fm.Value
            state.mode = 'FM';
        else
            state.mode = 'AM';
        end
        state.lbl_mode.Text = ['模式: ', state.mode, '解调'];
        % 模式切换时重置频道选择滤波器状态 (不同模式滤波器阶数不同)
        state.cs_zi = [];
        % 自动切换到该模式的经典频率
        if ~strcmp(state.mode, prev_mode)
            if strcmp(state.mode, 'FM')
                state.edit_fc.Value = 96.5;          % FM广播: 96.5 MHz
            else
                state.edit_fc.Value = 1;            % AM广播: 1 MHz (1000 kHz)
            end
            state.source_fc = state.edit_fc.Value * 1e6;
        end
    end

    function play_callback()
        if ~state.is_demod || isempty(state.audio)
            uialert(fig, '请先完成处理后再播放', '提示');
            return;
        end
        try
            clear sound;
            audio_out = state.audio / max(abs(state.audio)) * 0.9;
            sound(audio_out, state.audio_fs);
            state.lbl_status.Text = sprintf('播放中 - 时长 %.1f 秒', ...
                length(audio_out) / state.audio_fs);
            state.lbl_status.FontColor = [0 0.6 0];
        catch ME
            state.lbl_status.Text = ['播放失败: ', ME.message];
            state.lbl_status.FontColor = [0.8 0 0];
        end
    end

    function export_callback()
        if ~state.is_demod || isempty(state.audio)
            uialert(fig, '请先完成处理后再导出', '提示');
            return;
        end
        suggested = sprintf('sdr_%s_%s.wav', ...
            state.mode, datestr(now, 'yyyymmdd_HHMMSS'));
        [fname, fpath] = uiputfile({'*.wav', 'WAV音频文件 (*.wav)'}, ...
            '导出解调音频', suggested);
        if fname == 0
            return;
        end
        try
            audio_out = state.audio / max(abs(state.audio));
            audiowrite(fullfile(fpath, fname), audio_out, state.audio_fs, ...
                'BitsPerSample', 16, ...
                'Comment', sprintf('SDR Realtime %s Demodulation', state.mode));
            state.lbl_status.Text = ['已导出: ', fname];
            state.lbl_status.FontColor = [0 0.6 0];
        catch ME
            state.lbl_status.Text = ['导出失败: ', ME.message];
            state.lbl_status.FontColor = [0.8 0 0];
        end
    end

    function start_stop_callback()
        if state.running
            % 停止
            state.running = false;
            state.btn_start.Text = '▶ 开始处理';
            state.btn_start.BackgroundColor = [0.6 1.0 0.6];
            state.lbl_status.Text = '正在停止...';
            drawnow;
        else
            % 开始
            if strcmp(state.source_type, 'file') && isempty(state.source_filepath)
                uialert(fig, '请先选择IQ基带数据文件', '提示');
                return;
            end
            if strcmp(state.source_type, 'rtlsdr')
                if ~exist('comm.SDRRTLReceiver', 'class')
                    uialert(fig, ['未找到 RTL-SDR 支持包。', newline, ...
                        '请在MATLAB中运行 supportPackageInstaller，', newline, ...
                        '搜索安装 "Communications Toolbox Support Package for RTL-SDR Radio"'], ...
                        '缺少支持包');
                    return;
                end
            end


            % 读取参数
            state.source_fs   = state.edit_fs.Value * 1e6;
            state.source_fc   = state.edit_fc.Value * 1e6;
            state.source_gain = state.edit_gain.Value;
            state.f_offset    = state.edit_fo.Value * 1e3;
            state.frame_size  = str2double(state.dd_frame.Value);
            state.loop_playback = state.cb_loop.Value;

            % 设置按钮外观
            state.btn_start.Text = '■ 停止';
            state.btn_start.BackgroundColor = [1.0 0.4 0.4];

            % 锁定运行中不可修改的控件 (需硬件重启)
            state.dd_source.Enable = 'off';
            state.dd_frame.Enable = 'off';
            state.edit_fs.Editable = 'off';
            state.btn_browse.Enable = 'off';
            state.btn_play.Enable = 'off';
            state.btn_export.Enable = 'off';
            state.is_demod = false;
            % 以下控件可在运行中实时修改:
            %  edit_fc, edit_gain, edit_fo 保持可编辑

            drawnow;

            % 启动处理循环
            processing_loop();

            % 恢复控件
            state.dd_source.Enable = 'on';
            state.dd_frame.Enable = 'on';
            state.edit_fs.Editable = 'on';
            state.edit_fc.Editable = 'on';
            state.edit_gain.Editable = 'on';
            state.edit_fo.Editable = 'on';
            if strcmp(state.source_type, 'file')
                state.btn_browse.Enable = 'on';
            end
            state.btn_start.Text = '▶ 开始处理';
            state.btn_start.BackgroundColor = [0.6 1.0 0.6];
            state.running = false;
        end
    end

    function close_callback()
        if state.running
            state.running = false;
            pause(0.2);  % 等待循环退出
        end
        if state.source_fid > 0
            fclose(state.source_fid);
            state.source_fid = -1;
        end
        if ~isempty(state.source_handle)
            try
                release(state.source_handle);
            catch
            end
            state.source_handle = [];
        end
        if ~isempty(state.audio_writer)
            try
                release(state.audio_writer);
            catch
            end
            state.audio_writer = [];
        end
        if state.perf_log_fid > 0
            fclose(state.perf_log_fid);
            state.perf_log_fid = -1;
        end
        delete(fig);
    end

    %% ==================== 处理循环 ====================
    function processing_loop()
        state.running = true;

        % --- 打开数据源 ---
        if ~open_data_source()
            state.running = false;
            return;
        end

        % --- 创建音频输出 ---
        if state.use_audio_toolbox
            try
                state.audio_writer = audioDeviceWriter('SampleRate', state.audio_fs);
            catch ME
                state.lbl_status.Text = ['音频设备错误: ', ME.message];
                state.lbl_status.FontColor = [0.8 0 0];
                close_data_source();
                state.running = false;
                return;
            end
        end

        % --- 预设计所有滤波器 ---
        design_channel_filter();
        design_demod_filters();

        % --- 重置流式状态 ---
        reset_streaming_state();

        % --- 清空显示 ---
        cla(state.ax_spectrum);
        cla(state.ax_waterfall);
        cla(state.ax_audio);
        state.spectrum_line = [];
        state.waterfall_img = [];
        state.waterfall_buf = [];
        state.waterfall_idx = 1;
        state.audio_line = [];
        state.audio_buf = [];
        state.audio_buf_idx = 1;
        state.audio_accum = [];
        state.frame_count = 0;
        state.total_overruns = 0;

        % --- 性能统计 ---
        state.frame_times = zeros(100, 1);
        state.ft_idx = 1;
        state.t_start = tic;
        display_update_counter = 0;

        % --- 性能日志初始化 (含GUI开销) ---
        state.perf_last_snap = -inf;
        state.perf_log_file = fullfile(fileparts(mfilename('fullpath')), ...
            'perf-data.csv');
        % 若文件不存在则创建并写CSV表头
        if ~isfile(state.perf_log_file)
            fid_hdr = fopen(state.perf_log_file, 'w');
            if fid_hdr > 0
                fprintf(fid_hdr, 'timestamp,frame_size,elapsed_s,frame_count,total_overruns,avg_frame_ms,fps\n');
                fclose(fid_hdr);
            end
        end
        % 保持文件句柄打开, 避免运行时fopen/fclose开销
        state.perf_log_fid = fopen(state.perf_log_file, 'a');
        if state.perf_log_fid > 0
            fprintf(state.perf_log_fid, '# run %s, fc=%.1fMHz, fs=%.1fMSPS, gain=%ddB, frame_size=%d\n', ...
                char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
                state.source_fc/1e6, state.source_fs/1e6, state.source_gain, state.frame_size);
        end

        state.lbl_status.Text = '正在处理...';
        state.lbl_status.FontColor = [0 0.6 0];
        drawnow;

        % RTL-SDR 预热: 丢弃前5帧, 等待硬件稳定
        if strcmp(state.source_type, 'rtlsdr')
            for w = 1:5
                read_data_frame();
            end
            state.lbl_status.Text = 'RTL-SDR 实时接收中...';
        end

        % ===== 主循环 =====
        try
            while state.running
                t_frame = tic;

                % --- Step 0: 检查运行时参数是否被用户修改 ---
                apply_runtime_params();

                % --- Step 1: 读取一帧IQ数据 ---
                [iq_frame, is_done] = read_data_frame();
                if is_done
                    if strcmp(state.source_type, 'file') && state.loop_playback
                        rewind_file();
                        [iq_frame, ~] = read_data_frame();
                    else
                        break;
                    end
                end

                % --- Step 2: 频道选择 (DDC + LPF) ---
                if abs(state.f_offset) > 1  % 偏移<1Hz则跳过以节省计算
                    % 根据当前模式选择对应的滤波器
                    if strcmp(state.mode, 'AM')
                        cs_b = state.cs_b_am;
                    else
                        cs_b = state.cs_b_fm;
                    end
                    % DDC混频表缓存: f_offset未变则复用, 避免每帧重算exp
                    N_iq = length(iq_frame);
                    if isempty(state.ddc_table) || state.f_offset ~= state.ddc_table_offset || N_iq ~= state.ddc_table_N
                        t = (0:N_iq-1)' / state.source_fs;
                        state.ddc_table = exp(-1j * 2 * pi * state.f_offset * t);
                        state.ddc_table_offset = state.f_offset;
                        state.ddc_table_N = N_iq;
                    end
                    [iq_sel, state.cs_zi] = channel_select_stream(...
                        iq_frame, state.ddc_table, cs_b, state.cs_zi);
                else
                    iq_sel = iq_frame;
                end

                % --- Step 3: 解调 ---
                switch state.mode
                    case 'AM'
                        [audio_frame, state.am_dc_est, state.am_decim_stages] = ...
                            am_demodulate_stream(iq_sel, state.source_fs, state.audio_fs, ...
                                state.am_dc_est, state.am_dc_alpha, state.am_decim_stages);
                    case 'FM'
                        [audio_frame, state.fm_dc_est, state.fm_decim_stages, ...
                            state.fm_deemp_zi, state.fm_last_iq] = ...
                            fm_demodulate_stream(iq_sel, state.source_fs, state.audio_fs, ...
                                state.fm_dc_est, state.fm_dc_alpha, state.fm_decim_stages, ...
                                state.fm_deemp_b, state.fm_deemp_a, state.fm_deemp_zi, state.fm_last_iq);
                end

                % --- Step 4: 音频输出 ---
                % 累积音频 (用于导出, RTL-SDR限制30秒防止内存爆炸)
                max_accum = state.audio_fs * 30;
                if strcmp(state.source_type, 'file') || length(state.audio_accum) < max_accum
                    state.audio_accum = [state.audio_accum; audio_frame];
                end
                % 实时播放: audioDeviceWriter自然调速, 音画同步
                if state.use_audio_toolbox && ~isempty(state.audio_writer)
                    % RTL-SDR 实时: 低延迟流式输出
                    n_under = state.audio_writer(audio_frame);
                    state.total_overruns = state.total_overruns + n_under;
                else
                    % RTL-SDR 无AudioToolbox回退: 累积播放
                    state.audio_accum = [state.audio_accum; audio_frame];
                    accum_target = state.audio_fs * 0.3;
                    if length(state.audio_accum) >= accum_target
                        chunk = state.audio_accum(1:accum_target);
                        state.audio_accum = state.audio_accum(accum_target+1:end);
                        try
                            sound(chunk * 0.8, state.audio_fs);
                        catch
                        end
                    end
                end

                % --- Step 5: 更新显示 (节流: 每3帧) ---
                state.frame_count = state.frame_count + 1;
                display_update_counter = display_update_counter + 1;

                if display_update_counter >= 3
                    display_update_counter = 0;

                    % 计算FFT (用于频谱+瀑布图)
                    [pxx_db, f_khz] = compute_frame_fft_display(iq_frame, state.source_fs);

                    update_live_spectrum(f_khz, pxx_db);
                    update_waterfall(pxx_db, f_khz);
                    update_audio_display(audio_frame);

                    drawnow limitrate;

                    % 检查Stop按钮是否被按下
                    if ~state.running
                        break;
                    end
                end

                % --- Step 6: 性能统计 ---
                elapsed_ms = toc(t_frame) * 1000;
                state.frame_times(state.ft_idx) = elapsed_ms;
                state.ft_idx = mod(state.ft_idx, 100) + 1;

                % --- 文件回放调速: 强制等速, 消除卡顿 ---
                if strcmp(state.source_type, 'file')
                    t_audio = length(audio_frame) / state.audio_fs;
                    % 累计音频时长 = 目标时间线
                    t_target = state.frame_count * t_audio;
                    t_actual = toc(state.t_start);
                    if t_actual < t_target
                        pause(t_target - t_actual);
                    end
                end

                % 每~0.5秒更新状态面板 + 性能快照
                if mod(state.frame_count, 18) == 0
                    update_status_panel();
                    % 记录欠载快照 (10s, 20s, 30s, 45s, 60s)
                    record_perf_snapshot();
                end
            end

        catch ME
            % 处理循环异常
            state.lbl_status.Text = ['处理错误: ', ME.message];
            state.lbl_status.FontColor = [0.8 0 0];
            % 尝试显示更多调试信息
            try
                disp(getReport(ME, 'extended'));
            catch
            end
        end

        % ===== 保存累积音频供导出 =====
        if ~isempty(state.audio_accum)
            state.audio = state.audio_accum;
            state.is_demod = true;
            state.btn_play.Enable = 'on';
            state.btn_export.Enable = 'on';
        end

        % ===== 清理 =====
        if ~isempty(state.audio_writer)
            try
                release(state.audio_writer);
            catch
            end
            state.audio_writer = [];
        end
        close_data_source();

        if state.frame_count > 0 && ~state.loop_playback
            state.lbl_status.Text = sprintf('处理完成 - 共%d帧, %.1f秒', ...
                state.frame_count, toc(state.t_start));
        else
            state.lbl_status.Text = '已停止';
        end

        % 写入性能日志 (含GUI开销)
        write_perf_log();
        state.lbl_status.FontColor = [0 0.6 0];
        state.running = false;
    end

    %% ==================== 数据源函数 ====================

    function success = open_data_source()
        success = false;
        switch state.source_type
            case 'file'
                success = open_file_source();
            case 'rtlsdr'
                success = open_rtlsdr_source();
        end
    end

    function [iq_frame, done] = read_data_frame()
        switch state.source_type
            case 'file'
                [iq_frame, done] = read_file_frame();
            case 'rtlsdr'
                [iq_frame, done] = read_rtlsdr_frame();
        end
    end

    function close_data_source()
        switch state.source_type
            case 'file'
                close_file_source();
            case 'rtlsdr'
                close_rtlsdr_source();
        end
    end

    function success = open_file_source()
        filepath = state.source_filepath;
        finfo = dir(filepath);
        if isempty(finfo)
            error('文件不存在: %s', filepath);
        end

        % 获取采样率 (优先用audioinfo)
        try
            ainfo = audioinfo(filepath);
            state.source_fs = ainfo.SampleRate;
            state.source_data_len = ainfo.TotalSamples;
        catch
            try
                [~, fs_r] = audioread(filepath, [1, 1000]);
                state.source_fs = fs_r;
                state.source_data_len = floor(finfo.bytes / 4);
            catch ME
                state.lbl_status.Text = ['文件读取失败: ', ME.message];
                state.lbl_status.FontColor = [0.8 0 0];
                success = false;
                return;
            end
        end

        % 打开文件句柄 (用于fread回退)
        state.source_fid = fopen(filepath, 'rb');
        if state.source_fid < 0
            state.lbl_status.Text = '无法打开文件';
            state.lbl_status.FontColor = [0.8 0 0];
            success = false;
            return;
        end

        state.source_read_pos = 0;
        state.edit_fs.Value = state.source_fs / 1e6;

        state.lbl_status.Text = sprintf('已打开: %s', state.lbl_file.Text);
        state.lbl_status.FontColor = [0 0.6 0];
        success = true;
    end

    function [iq_frame, done] = read_file_frame()
        N = state.frame_size;
        start_sample = state.source_read_pos + 1;
        end_sample = min(start_sample + N - 1, state.source_data_len);

        if start_sample > state.source_data_len
            iq_frame = zeros(N, 1);
            done = true;
            return;
        end

        % 使用 audioread 范围读取 (R2015a+支持WAV, R2020b+支持所有格式)
        data = audioread(state.source_filepath, [start_sample, end_sample], 'native');

        I = double(data(:, 1));
        Q = double(data(:, 2));
        iq_frame = complex(I, Q);

        state.source_read_pos = end_sample;
        done = (end_sample >= state.source_data_len);

        % 末帧补零
        actual_len = length(iq_frame);
        if actual_len < N
            iq_frame = [iq_frame; zeros(N - actual_len, 1, 'like', iq_frame)];
        end
    end

    function rewind_file()
        state.source_read_pos = 0;
        if state.source_fid > 0
            fseek(state.source_fid, 0, 'bof');
        end
    end

    function close_file_source()
        if state.source_fid > 0
            fclose(state.source_fid);
            state.source_fid = -1;
        end
    end

    % ---- RTL-SDR 硬件数据源 ----
    function success = open_rtlsdr_source()
        try
            % RTL-SDR要求SamplesPerFrame ≤ 32768, 大帧通过多次读取拼接
            rtl_frame = min(state.frame_size, 32768);
            state.source_handle = comm.SDRRTLReceiver('0', ...
                'CenterFrequency',     state.source_fc, ...
                'SampleRate',          state.source_fs, ...
                'OutputDataType',      'double', ...
                'SamplesPerFrame',     rtl_frame, ...
                'EnableTunerAGC',      false, ...
                'TunerGain',           state.source_gain);
            % 获取实际采样率 (硬件可能不完全等于请求值)
            actual_fs = state.source_handle.SampleRate;
            state.source_fs = actual_fs;
            state.edit_fs.Value = actual_fs / 1e6;
            state.lbl_status.Text = sprintf('RTL-SDR已连接 @ %.3f MHz, %.3f MSPS', ...
                state.source_fc/1e6, actual_fs/1e6);
            state.lbl_status.FontColor = [0 0.6 0];
            success = true;
        catch ME
            state.lbl_status.Text = ['RTL-SDR连接失败: ', ME.message];
            state.lbl_status.FontColor = [0.8 0 0];
            success = false;
        end
    end

    function [iq_frame, done] = read_rtlsdr_frame()
        % RTL-SDR 连续流, 永不结束. 硬件每次最多32768, 大帧多次读取拼接
        rtl_frame = min(state.frame_size, 32768);
        n_chunks = ceil(state.frame_size / rtl_frame);
        iq_frame = zeros(state.frame_size, 1);
        try
            for c = 1:n_chunks
                chunk = state.source_handle();
                chunk = chunk(:);
                i0 = (c - 1) * rtl_frame + 1;
                i1 = min(i0 + rtl_frame - 1, state.frame_size);
                n_take = i1 - i0 + 1;
                iq_frame(i0:i1) = chunk(1:n_take);
            end
            done = false;
        catch ME
            state.lbl_status.Text = ['RTL-SDR读取错误: ', ME.message];
            state.lbl_status.FontColor = [0.8 0.4 0];
            iq_frame = zeros(state.frame_size, 1);
            done = false;
        end
    end

    function close_rtlsdr_source()
        if ~isempty(state.source_handle)
            try
                release(state.source_handle);
            catch
            end
            state.source_handle = [];
        end
    end

    %% ==================== 运行时参数即时更新 ====================
    function apply_runtime_params()
        % 允许在接收过程中实时调整: 中心频率、增益、解调偏移
        new_fc    = state.edit_fc.Value * 1e6;
        new_gain  = state.edit_gain.Value;
        new_offset = state.edit_fo.Value * 1e3;

        % 中心频率变更 → 更新硬件
        if abs(new_fc - state.source_fc) > 1  % 变化超过1Hz
            state.source_fc = new_fc;
            if strcmp(state.source_type, 'rtlsdr') && ~isempty(state.source_handle)
                try
                    state.source_handle.CenterFrequency = new_fc;
                    state.lbl_status.Text = sprintf('已调谐到 %.3f MHz', new_fc/1e6);
                    state.lbl_status.FontColor = [0 0.6 0];
                catch
                end
            end
        end

        % 增益变更 → 更新硬件
        if new_gain ~= state.source_gain
            state.source_gain = new_gain;
            if strcmp(state.source_type, 'rtlsdr') && ~isempty(state.source_handle)
                try
                    state.source_handle.TunerGain = new_gain;
                catch
                end
            end
        end

        % 解调偏移变更 (仅影响软件, 无需硬件操作)
        if abs(new_offset - state.f_offset) > 0.1
            state.f_offset = new_offset;
        end
    end

    %% ==================== 滤波器设计 (处理循环开始时调用) ====================

    function design_channel_filter()
        % 为两种模式各设计一个频道选择滤波器 (60dB衰减)
        % FM: 120 kHz 带宽
        bw_fm = 120000;
        filt_stop = bw_fm * 1.15;
        try
            lp_filt = designfilt('lowpassfir', ...
                'PassbandFrequency', bw_fm, 'StopbandFrequency', filt_stop, ...
                'PassbandRipple', 0.01, 'StopbandAttenuation', 60, ...
                'SampleRate', state.source_fs, 'DesignMethod', 'kaiserwin');
            state.cs_b_fm = lp_filt.Coefficients;
        catch
            N_fir = min(512, round(state.source_fs / bw_fm * 3));
            state.cs_b_fm = fir1(N_fir, bw_fm / (state.source_fs / 2), 'low');
        end

        % AM: 6 kHz 带宽
        bw_am = 6000;
        filt_stop = bw_am * 1.15;
        try
            lp_filt = designfilt('lowpassfir', ...
                'PassbandFrequency', bw_am, 'StopbandFrequency', filt_stop, ...
                'PassbandRipple', 0.01, 'StopbandAttenuation', 60, ...
                'SampleRate', state.source_fs, 'DesignMethod', 'kaiserwin');
            state.cs_b_am = lp_filt.Coefficients;
        catch
            N_fir = min(512, round(state.source_fs / bw_am * 3));
            state.cs_b_am = fir1(N_fir, bw_am / (state.source_fs / 2), 'low');
        end

        state.cs_zi = [];
    end

    function design_demod_filters()
        % 多级降采样级联在首次调用multistage_decimate_stream时自动设计
        state.am_decim_stages = [];
        state.fm_decim_stages = [];

        % 去加重滤波器 (FM, 50us, 中国/欧洲标准)
        tau = 50e-6;
        alpha = exp(-1 / (state.audio_fs * tau));
        state.fm_deemp_b = 1 - alpha;
        state.fm_deemp_a = [1, -alpha];
        state.fm_deemp_zi = [];
    end

    function reset_streaming_state()
        state.cs_zi = [];
        state.am_dc_est = 0;
        state.am_decim_stages = [];
        state.fm_dc_est = 0;
        state.fm_decim_stages = [];
        state.fm_last_iq = complex(NaN);
        state.fm_deemp_zi = [];
    end

    %% ==================== 显示更新函数 ====================

    function update_live_spectrum(f_khz, pxx_db)
        ax = state.ax_spectrum;
        if isempty(state.spectrum_line) || ~isvalid(state.spectrum_line)
            cla(ax);
            state.spectrum_line = plot(ax, f_khz, pxx_db, 'b-', 'LineWidth', 0.8);
            xlabel(ax, '频率 (kHz)');
            ylabel(ax, '功率 (dB)');
            title(ax, sprintf('实时频谱 (FFT, %s)', state.mode));
            grid(ax, 'on');
            set_spectrum_range(ax);

            % 自适应Y轴范围
            p_valid = pxx_db(isfinite(pxx_db));
            if ~isempty(p_valid)
                noise_floor = median(p_valid);
                ylim(ax, [noise_floor - 10, noise_floor + 60]);
            end
        else
            set(state.spectrum_line, 'XData', f_khz, 'YData', pxx_db);
            set_spectrum_range(ax);

            % 缓慢跟踪Y轴范围
            p_valid = pxx_db(isfinite(pxx_db));
            if ~isempty(p_valid)
                noise_floor = median(p_valid);
                curr_ylim = ylim(ax);
                target_lo = noise_floor - 10;
                target_hi = noise_floor + 60;
                new_lo = curr_ylim(1) * 0.9 + target_lo * 0.1;
                new_hi = curr_ylim(2) * 0.9 + target_hi * 0.1;
                ylim(ax, [new_lo, new_hi]);
            end
        end

        % 每10帧做一次信号检测并标注
        if mod(state.frame_count, 30) == 0
            try
                signals = detect_signals(f_khz * 1e3, pxx_db, state.mode);
                plot_signal_annotations(ax, signals);
            catch
            end
        end
    end

    function set_spectrum_range(ax)
        % AM: ±30 kHz 窄带显示, FM: 全Nyquist带宽
        if strcmp(state.mode, 'AM')
            xlim(ax, [-30, 30]);
        else
            xlim(ax, [-state.source_fs/2e3, state.source_fs/2e3]);
        end
    end

    function plot_signal_annotations(ax, signals)
        delete(findobj(ax, 'Tag', 'SignalAnno'));

        colors = lines(min(length(signals), 7));
        for k = 1:length(signals)
            s = signals(k);
            c = colors(k, :);
            f_center_khz = s.freq / 1e3;
            bw_half_khz = s.bw / 2e3;

            xline(ax, f_center_khz, '-', 'Color', c, 'LineWidth', 1.5, 'Tag', 'SignalAnno');
            xline(ax, f_center_khz - bw_half_khz, ':', 'Color', c, 'LineWidth', 0.6, 'Tag', 'SignalAnno');
            xline(ax, f_center_khz + bw_half_khz, ':', 'Color', c, 'LineWidth', 0.6, 'Tag', 'SignalAnno');

            y_top = s.peak_pwr + 2;
            text(ax, f_center_khz, y_top, sprintf('%.1f kHz', f_center_khz), ...
                'Color', c, 'FontSize', 8, 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
                'Tag', 'SignalAnno');
        end
    end

    function update_waterfall(pxx_db, f_khz)
        ax = state.ax_waterfall;
        n_bins = length(pxx_db);

        if isempty(state.waterfall_buf)
            state.waterfall_buf = zeros(state.waterfall_max, n_bins);
            state.waterfall_freq = f_khz;
        end

        % 环形缓冲写入
        state.waterfall_buf(state.waterfall_idx, :) = pxx_db;
        state.waterfall_idx = mod(state.waterfall_idx, state.waterfall_max) + 1;

        % 按显示顺序排列: row 1 = 最新 (顶部), 向下流动
        if state.waterfall_idx == 1
            ordered = state.waterfall_buf;
        else
            ordered = state.waterfall_buf([state.waterfall_idx:end, 1:state.waterfall_idx-1], :);
        end
        % 不翻转: row 1(最新)→axes顶部, row end(最旧)→axes底部, 符合瀑布直觉

        % 动态颜色范围
        p_valid = pxx_db(isfinite(pxx_db));
        if ~isempty(p_valid)
            noise_ref = prctile(p_valid, 10);
            c_low = noise_ref + 3;
            c_high = c_low + 40;
        else
            c_low = -60;
            c_high = 0;
        end

        if isempty(state.waterfall_img) || ~isvalid(state.waterfall_img)
            cla(ax);
            state.waterfall_img = imagesc(ax, state.waterfall_freq, ...
                1:state.waterfall_max, ordered, [c_low, c_high]);
            set(ax, 'YDir', 'normal');
            try
                colormap(ax, 'turbo');
            catch
                try
                    colormap(ax, 'parula');
                catch
                    colormap(ax, 'jet');
                end
            end
            set(ax, 'Color', [0.02 0.02 0.08]);
            cb = colorbar(ax);
            cb.Label.String = '功率 (dB)';
            xlabel(ax, '频率 (kHz)');
            ylabel(ax, '帧序号 (新→旧 ↓)');
            title(ax, '实时瀑布图 (最新在顶部)');
            set_spectrum_range(ax);
        else
            set(state.waterfall_img, 'CData', ordered);
            caxis(ax, [c_low, c_high]);
            set_spectrum_range(ax);
        end
    end

    function update_audio_display(audio_frame)
        ax = state.ax_audio;
        buf_len = state.audio_fs * 2;  % 2秒缓冲

        if isempty(state.audio_buf)
            state.audio_buf = zeros(buf_len, 1);
            state.audio_buf_idx = 1;
        end

        n = length(audio_frame);
        idx_end = state.audio_buf_idx + n - 1;
        if idx_end <= buf_len
            state.audio_buf(state.audio_buf_idx:idx_end) = audio_frame;
        else
            n1 = buf_len - state.audio_buf_idx + 1;
            state.audio_buf(state.audio_buf_idx:end) = audio_frame(1:n1);
            state.audio_buf(1:n - n1) = audio_frame(n1+1:end);
        end
        state.audio_buf_idx = mod(idx_end, buf_len) + 1;

        t = (0:buf_len-1)' / state.audio_fs;

        if isempty(state.audio_line) || ~isvalid(state.audio_line)
            cla(ax);
            state.audio_line = plot(ax, t, state.audio_buf, 'b-', 'LineWidth', 0.5);
            xlabel(ax, '时间 (s)');
            ylabel(ax, '幅度');
            title(ax, '实时音频波形 (最近2秒)');
            grid(ax, 'on');
            ylim(ax, [-1.1, 1.1]);
            xlim(ax, [0, 2]);
        else
            set(state.audio_line, 'YData', state.audio_buf);
        end
    end

    function update_status_panel()
        avg_ms = mean(state.frame_times(state.frame_times > 0));
        if avg_ms > 0
            fps = 1000 / avg_ms;
        else
            fps = 0;
        end
        total_sec = toc(state.t_start);

        mins = floor(total_sec / 60);
        secs = floor(mod(total_sec, 60));
        time_str = sprintf('%02d:%02d', mins, secs);

        state.txt_status.Value = {...
            sprintf('帧率: %.1f fps', fps); ...
            sprintf('处理: %.1f ms/帧', avg_ms); ...
            sprintf('欠载: %d 次', state.total_overruns); ...
            sprintf('帧数: %d', state.frame_count); ...
            sprintf('运行: %s', time_str) ...
        };

        state.lbl_perf.Text = sprintf('%.0f fps | %.1f ms/帧', fps, avg_ms);
    end

    % --- 性能日志: 每~5秒追加一行原始数据 (无fopen/fclose, 零开销) ---
    function record_perf_snapshot()
        if state.perf_log_fid < 0
            return;
        end
        elapsed = toc(state.t_start);
        if elapsed - state.perf_last_snap < 5
            return;
        end
        state.perf_last_snap = elapsed;
        avg_ms = mean(state.frame_times(state.frame_times > 0));
        if isempty(avg_ms) || isnan(avg_ms) || avg_ms == 0
            fps = 0;
        else
            fps = 1000 / avg_ms;
        end
        fprintf(state.perf_log_fid, '%s,%d,%.1f,%d,%d,%.1f,%.1f\n', ...
            char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
            state.frame_size, elapsed, state.frame_count, ...
            state.total_overruns, avg_ms, fps);
    end

    % --- 性能日志: 关闭文件 ---
    function write_perf_log()
        if state.perf_log_fid > 0
            fprintf(state.perf_log_fid, '# end of run, total_frames=%d, total_time=%.1fs\n\n', ...
                state.frame_count, toc(state.t_start));
            fclose(state.perf_log_fid);
            state.perf_log_fid = -1;
        end
    end

end  % sdr_realtime_processor 主函数结束


%% ==================== 流式频道选择 ====================
function [iq_out, cs_zi] = channel_select_stream(iq_frame, ddc_table, filt_b, cs_zi)
% 流式数字下变频 + 信道滤波 (保持滤波器状态跨帧连续)
%   iq_frame  - 输入IQ帧 (N×1 complex)
%   ddc_table - 预计算的DDC混频表 exp(-1j*2*pi*f_offset*t), 调用方缓存避免每帧重算
%   filt_b    - FIR低通滤波器系数
%   cs_zi     - 滤波器延迟线状态 ([] = 初始化)
%   iq_out    - 频道选择后的IQ信号
%   cs_zi     - 更新后的滤波器状态

    % DDC: 将目标信号搬移到DC (使用预计算混频表)
    iq_shifted = iq_frame .* ddc_table;

    % LPF + 状态连续性
    [iq_out, cs_zi] = filter(filt_b, 1, iq_shifted, cs_zi);
    iq_out = iq_out(:);
end


%% ==================== 流式AM解调 ====================
function [audio_frame, dc_est, decim_stages] = am_demodulate_stream(iq, fs, audio_fs, dc_est, dc_alpha, decim_stages)
% 流式AM包络检波解调
%   状态变量 (跨帧持续):
%     dc_est       - DC运行均值估计
%     dc_alpha     - 平滑系数 (0.999)
%     decim_stages - 多级降采样状态数组

    % 1. 包络检波
    envelope = abs(iq);

    % 2. 去直流 (运行指数均值)
    frame_mean = mean(envelope);
    if dc_est == 0
        dc_est = frame_mean;
    else
        dc_est = dc_alpha * dc_est + (1 - dc_alpha) * frame_mean;
    end
    envelope = envelope - dc_est;

    % 3. 多级降采样 (含低通滤波)
    [audio_frame, decim_stages] = multistage_decimate_stream(...
        envelope, fs, audio_fs, 5000, decim_stages);

    % 4. 逐帧归一化
    peak = max(abs(audio_frame));
    if peak > 1e-9
        audio_frame = audio_frame / peak * 0.8;
    end
end


%% ==================== 流式FM解调 ====================
function [audio_frame, dc_est, decim_stages, deemp_zi, last_iq] = ...
    fm_demodulate_stream(iq_frame, fs, audio_fs, dc_est, dc_alpha, decim_stages, ...
                         deemp_b, deemp_a, deemp_zi, last_iq)
% 流式FM正交鉴频解调
%   状态变量 (跨帧持续):
%     dc_est       - DC运行均值估计
%     decim_stages - 多级降采样状态
%     deemp_zi     - 去加重滤波器延迟线
%     last_iq      - 前一帧最后一个IQ样点 (相位连续)

    N = length(iq_frame);

    % 1. 瞬时频率 (处理相位连续性)
    if ~isnan(last_iq)
        % 有前一帧的状态: 拼接保证 unwrap 连续
        iq_ext = [last_iq; iq_frame(:)];
        phi = atan2(imag(iq_ext), real(iq_ext));
        phi_uw = unwrap(phi);
        freq_inst = diff(phi_uw) * fs / (2 * pi);
        % freq_inst 长度为 N (iq_frame 的长度)
    else
        % 首帧: 无前一帧样点, 使用首样点填充
        phi = atan2(imag(iq_frame), real(iq_frame));
        phi_uw = unwrap(phi);
        freq_inst = diff(phi_uw) * fs / (2 * pi);
        freq_inst = [freq_inst(1); freq_inst];  % 保持N长度
    end

    % 保存末样点供下一帧使用
    last_iq = iq_frame(end);

    % 2. 去直流 (运行指数均值)
    frame_mean = mean(freq_inst);
    if dc_est == 0
        dc_est = frame_mean;
    else
        dc_est = dc_alpha * dc_est + (1 - dc_alpha) * frame_mean;
    end
    freq_inst = freq_inst - dc_est;

    % 3. 多级降采样
    [audio_raw, decim_stages] = multistage_decimate_stream(...
        freq_inst, fs, audio_fs, 15000, decim_stages);

    % 4. 去加重 (保持状态)
    [audio_frame, deemp_zi] = filter(deemp_b, deemp_a, audio_raw, deemp_zi);

    % 5. 逐帧去直流 + 归一化
    audio_frame = audio_frame - mean(audio_frame);
    peak = max(abs(audio_frame));
    if peak > 1e-9
        audio_frame = audio_frame / peak * 0.8;
    end
end


%% ==================== 流式多级降采样 ====================
function [y, stages] = multistage_decimate_stream(x, fs_in, fs_out, lp_cutoff, stages)
% 流式多级降采样, 每级D≤10, 保持各级滤波器状态
%   x         - 输入信号
%   fs_in     - 输入采样率
%   fs_out    - 输出采样率
%   lp_cutoff - 抗混叠低通截止频率
%   stages    - 降采样级状态数组 (struct: .b, .D, .zi)
%   y         - 降采样后信号
%   stages    - 更新后的状态

    y = x(:);
    fs_current = fs_in;

    % --- 首帧: 设计降采样级联 ---
    if isempty(stages)
        stages = struct('b', {}, 'D', {}, 'zi', {});
        stage_idx = 0;

        while fs_current > fs_out * 1.5
            D = min(10, floor(fs_current / fs_out));
            if D < 2
                D = 2;
            end
            if fs_current / D < fs_out
                D = round(fs_current / fs_out);
                if D < 2
                    break;
                end
            end
            fs_new = fs_current / D;

            filt_cutoff = min(lp_cutoff, fs_new * 0.45);
            filt_stop = fs_new * 0.5;

            try
                fir_filt = designfilt('lowpassfir', ...
                    'PassbandFrequency', filt_cutoff, ...
                    'StopbandFrequency', filt_stop, ...
                    'PassbandRipple', 0.01, ...
                    'StopbandAttenuation', 60, ...
                    'SampleRate', fs_current, ...
                    'DesignMethod', 'kaiserwin');
                b = fir_filt.Coefficients;
            catch
                N_fir = min(256, round(fs_current / filt_cutoff * 4));
                b = fir1(N_fir, filt_cutoff / (fs_current / 2));
            end

            stage_idx = stage_idx + 1;
            stages(stage_idx).b  = b(:);
            stages(stage_idx).D  = D;
            stages(stage_idx).zi = [];

            fs_current = fs_new;
        end

        % 末级分数比降采样 (使用resample, 仅在必要时)
        if fs_current ~= fs_out
            stage_idx = stage_idx + 1;
            stages(stage_idx).b  = [];  % 标记: 使用resample
            stages(stage_idx).D  = fs_out / fs_current;
            stages(stage_idx).zi = [];
        end
    end

    % --- 逐级处理 ---
    for i = 1:length(stages)
        stg = stages(i);

        if isempty(stg.b)
            % 末级 resample (不保持状态, 边界有不连续但影响极小)
            [p, q] = rat(stg.D, 0.001);
            y = resample(y, p, q);
        else
            % FIR滤波 + 状态保持 + 降采样
            [y_filt, stages(i).zi] = filter(stg.b, 1, y, stg.zi);
            y = y_filt(1:stg.D:end);
        end
    end

    y = y(:);
end


%% ==================== 实时FFT计算 ====================
function [pxx_db, f_khz] = compute_frame_fft_display(iq_frame, fs)
% 计算单帧FFT用于实时显示
% 使用Welch方法: 将大帧分成多个小段做平均, 减少方差

    frame_len = length(iq_frame);
    seg_len = 4096;
    nfft = 8192;
    overlap = seg_len / 2;

    if frame_len < seg_len
        seg_len = frame_len;
        nfft = 2^nextpow2(seg_len);
        overlap = 0;
    end

    n_segs = floor((frame_len - overlap) / (seg_len - overlap));
    if n_segs < 1
        n_segs = 1;
    end
    n_segs = min(n_segs, 16);  % 最多16段平均

    win = hann(seg_len);
    pxx_accum = zeros(nfft, 1);

    for s = 1:n_segs
        start_idx = (s - 1) * (seg_len - overlap) + 1;
        seg = iq_frame(start_idx:min(start_idx + seg_len - 1, frame_len));
        if length(seg) < seg_len
            seg_w = [seg(:); zeros(seg_len - length(seg), 1)] .* win;
        else
            seg_w = seg(:) .* win;
        end
        seg_fft = fft(seg_w, nfft);
        pxx_accum = pxx_accum + abs(seg_fft).^2;
    end

    pxx = pxx_accum / n_segs;
    pxx_db = fftshift(10 * log10(pxx / seg_len^2 + eps));
    f_khz = ((0:nfft-1)' / nfft * fs - fs/2) / 1e3;
end


%% ==================== 信号检测 (从离线版本复用) ====================
function signals = detect_signals(f_centered, pxx_db, mode)
% 基于局部自适应噪声基底的信号检测
% 从 sdr_offline_processor.m 移植, 用于实时频谱标注
%
%   f_centered - 频率向量 (Hz, -fs/2 ~ +fs/2, 已fftshift)
%   pxx_db     - PSD (dB, 已fftshift)
%   mode       - 'AM' | 'FM'
%   signals    - 结构数组: .freq(Hz) .snr(dB) .bw(Hz) .peak_pwr(dB)

    df = f_centered(2) - f_centered(1);
    N  = length(pxx_db);

    switch upper(mode)
        case 'FM'
            local_wnd   = 350e3;
            snr_margin  = 5.5;
            min_bw      = 25e3;
            max_bw      = 320e3;
            gap_khz     = 10;
        case 'AM'
            local_wnd   = 60e3;
            snr_margin  = 7;
            min_bw      = 2e3;
            max_bw      = 25e3;
            gap_khz     = 2;
    end

    % 局部噪声基底: 移动15%分位数
    half_bins = round(local_wnd / df / 2);
    half_bins = max(half_bins, 10);

    step = max(1, round(half_bins / 3));
    sample_idx = [1:step:N, N];
    noise_samp = zeros(size(sample_idx));
    for i = 1:length(sample_idx)
        lo = max(1, sample_idx(i) - half_bins);
        hi = min(N, sample_idx(i) + half_bins);
        noise_samp(i) = prctile(pxx_db(lo:hi), 15);
    end
    noise_local = interp1(sample_idx, noise_samp, 1:N, 'pchip')';

    % 自适应门限 + 二值化
    threshold = noise_local + snr_margin;
    above = pxx_db > threshold;

    % 屏蔽DC (±500 Hz)
    dc_hz = 500;
    dc_bins = round(dc_hz / df);
    dc_center = round(N/2);
    dc_lo = max(1, dc_center - dc_bins);
    dc_hi = min(N, dc_center + dc_bins);
    above(dc_lo:dc_hi) = false;

    if ~any(above)
        signals = struct('freq', {}, 'snr', {}, 'bw', {}, 'peak_pwr', {});
        return;
    end

    % 形态学闭运算 (桥接窄缝)
    gap_bins = max(1, round(gap_khz * 1e3 / df));
    dilated = false(N, 1);
    for i = 1:N
        lo = max(1, i - gap_bins);
        hi = min(N, i + gap_bins);
        dilated(i) = any(above(lo:hi));
    end
    closed = false(N, 1);
    for i = 1:N
        lo = max(1, i - gap_bins);
        hi = min(N, i + gap_bins);
        closed(i) = all(dilated(lo:hi));
    end

    % 连通域标记
    labels = zeros(N, 1);
    curr_label = 0;
    in_region = false;
    for i = 1:N
        if closed(i) && ~in_region
            curr_label = curr_label + 1;
            in_region = true;
        elseif ~closed(i) && in_region
            in_region = false;
        end
        if in_region
            labels(i) = curr_label;
        end
    end
    n_regions = curr_label;
    if n_regions == 0
        signals = struct('freq', {}, 'snr', {}, 'bw', {}, 'peak_pwr', {});
        return;
    end

    % 分析区域
    sig_list = struct('freq', cell(1, n_regions), 'snr', [], ...
                      'bw', [], 'peak_pwr', []);
    sig_count = 0;
    for r = 1:n_regions
        mask = (labels == r);
        f_reg = f_centered(mask);
        p_reg = pxx_db(mask);

        bw = f_reg(end) - f_reg(1);
        if bw < min_bw || bw > max_bw
            continue;
        end

        p_lin = 10.^(p_reg / 10);
        fc_est = sum(f_reg .* p_lin) / sum(p_lin);

        [peak_pwr, ~] = max(p_reg);
        [~, center_bin] = min(abs(f_centered - fc_est));
        local_noise_at_peak = noise_local(center_bin);
        snr = peak_pwr - local_noise_at_peak;

        if snr < snr_margin
            continue;
        end

        sig_count = sig_count + 1;
        sig_list(sig_count).freq     = fc_est;
        sig_list(sig_count).snr      = snr;
        sig_list(sig_count).bw       = bw;
        sig_list(sig_count).peak_pwr = peak_pwr;
    end
    sig_list = sig_list(1:sig_count);

    if sig_count == 0
        signals = struct('freq', {}, 'snr', {}, 'bw', {}, 'peak_pwr', {});
    else
        [~, order] = sort([sig_list.snr], 'descend');
        signals = sig_list(order);
    end
end
