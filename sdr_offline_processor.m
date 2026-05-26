function sdr_offline_processor()
% SDR基带数据分析与解调系统
% 功能: 读取WAV/RF64格式的IQ基带数据，完成AM/FM信号的频谱分析与非实时解调
% 输入: WAV RF64格式, 16-bit IQ立体声 (左声道=I, 右声道=Q)
% 输出: 频谱显示, 瀑布图, 解调音频播放/导出

    %% ==================== 全局状态 ====================
    state = struct(...
        'iq_data',      [], ...       % IQ复信号
        'fs',           0, ...        % 采样率 (Hz)
        'fc',           100e6, ...    % 中心频率 (Hz)
        'audio',        [], ...       % 解调后的音频
        'audio_fs',     48000, ...    % 音频采样率
        'mode',         'FM', ...     % 解调模式 'AM' | 'FM'
        'filename',     '', ...       % 当前文件名
        'is_loaded',    false, ...    % 是否已加载文件
        'is_demod',     false, ...    % 是否已完成解调
        'file_size_mb', 0, ...        % 文件大小 (MB)
        'duration_sec', 0 ...         % 录音时长 (秒)
    );

    %% ==================== GUI 构建 ====================
    % 关闭已存在的旧窗口，避免多开
    old_figs = findall(0, 'Type', 'figure', 'Tag', 'SdrOfflineProcessor');
    if ~isempty(old_figs)
        close(old_figs);
    end

    fig = uifigure('Name', 'SDR基带数据分析与解调系统', ...
                   'Position', [100, 40, 1200, 760], ...
                   'Resize', 'on', ...
                   'Tag', 'SdrOfflineProcessor', ...
                   'Color', [0.94 0.94 0.94]);

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

    % 左侧控制面板
    ctrl_panel = uipanel(top_grid, 'Title', '控制面板', ...
                         'FontSize', 13, 'FontWeight', 'bold');

    ctrl_grid = uigridlayout(ctrl_panel, [13, 1]);
    ctrl_grid.RowHeight = {22, 22, 100, 22, 36, 36, 36, 22, 50, 40, 40, 40, '1x'};
    ctrl_grid.Padding = [8, 8, 8, 8];
    ctrl_grid.RowSpacing = 4;

    % 文件信息区
    uilabel(ctrl_grid, 'Text', '━━ 文件信息 ━━', ...
            'FontWeight', 'bold', 'HorizontalAlignment', 'center');

    state.lbl_file = uilabel(ctrl_grid, 'Text', '未加载文件', ...
        'FontColor', [0.5 0.5 0.5]);

    state.lbl_info = uilabel(ctrl_grid, 'Text', '等待选择文件...', ...
        'FontColor', [0.4 0.4 0.4], 'WordWrap', 'on');

    % 手动设置参数区 (当WAV头无法读取时使用)
    uilabel(ctrl_grid, 'Text', '━━ 参数设置 ━━', ...
            'FontWeight', 'bold', 'HorizontalAlignment', 'center');

    % 采样率
    fs_row = uigridlayout(ctrl_grid, [1, 2]);
    fs_row.ColumnWidth = {65, '1x'};
    fs_row.Padding = [2, 0, 2, 0];
    fs_row.RowSpacing = 0;
    uilabel(fs_row, 'Text', '采样率:');
    state.edit_fs = uieditfield(fs_row, 'numeric', ...
        'Value', 2.4, 'ValueDisplayFormat', '%.3f MSPS', ...
        'Tag', 'fs');

    % 中心频率
    fc_row = uigridlayout(ctrl_grid, [1, 2]);
    fc_row.ColumnWidth = {65, '1x'};
    fc_row.Padding = [2, 0, 2, 0];
    fc_row.RowSpacing = 0;
    uilabel(fc_row, 'Text', '中心频率:');
    state.edit_fc = uieditfield(fc_row, 'numeric', ...
        'Value', 100, 'ValueDisplayFormat', '%.2f MHz', ...
        'Tag', 'fc');

    % 基带偏移 (关键: 电台在基带中偏离DC的频率)
    fo_row = uigridlayout(ctrl_grid, [1, 2]);
    fo_row.ColumnWidth = {65, '1x'};
    fo_row.Padding = [2, 0, 2, 0];
    fo_row.RowSpacing = 0;
    uilabel(fo_row, 'Text', '解调偏移:');
    state.edit_fo = uieditfield(fo_row, 'numeric', ...
        'Value', 0, 'ValueDisplayFormat', '%.1f kHz', ...
        'Tag', 'fo', ...
        'Tooltip', '目标信号在基带中的频率偏移, 看频谱图确定峰值位置后填入');

    % 解调模式
    uilabel(ctrl_grid, 'Text', '━━ 解调设置 ━━', ...
            'FontWeight', 'bold', 'HorizontalAlignment', 'center');

    mode_group = uibuttongroup(ctrl_grid);
    state.rb_fm = uiradiobutton(mode_group, 'Text', 'FM 宽带解调', ...
        'Value', 1, 'Position', [8, 10, 120, 22]);
    state.rb_am = uiradiobutton(mode_group, 'Text', 'AM 解调', ...
        'Position', [140, 10, 90, 22]);

    % 操作按钮
    state.btn_load = uibutton(ctrl_grid, 'push', ...
        'Text', '加载 IQ 文件', ...
        'ButtonPushedFcn', @(src, evt) load_file_callback(), ...
        'FontWeight', 'bold');

    state.btn_analyze = uibutton(ctrl_grid, 'push', ...
        'Text', '开始分析', ...
        'ButtonPushedFcn', @(src, evt) analyze_callback(), ...
        'Enable', 'off', ...
        'FontWeight', 'bold');

    state.btn_play = uibutton(ctrl_grid, 'push', ...
        'Text', '播放解调音频', ...
        'ButtonPushedFcn', @(src, evt) play_callback(), ...
        'Enable', 'off');

    state.btn_export = uibutton(ctrl_grid, 'push', ...
        'Text', '导出 WAV 文件', ...
        'ButtonPushedFcn', @(src, evt) export_callback(), ...
        'Enable', 'off');

    % 右侧显示区域 — 使用 Tab 组织
    right_panel = uipanel(top_grid, 'Title', '分析结果', ...
                          'FontSize', 13, 'FontWeight', 'bold');

    tab_group = uitabgroup(right_panel);

    % Tab 1: 频谱分析
    tab_spec = uitab(tab_group, 'Title', '频谱分析');
    spec_grid = uigridlayout(tab_spec, [2, 1]);
    spec_grid.RowHeight = {'1x', '1x'};

    state.ax_spectrum = uiaxes(spec_grid);
    title(state.ax_spectrum, '功率谱密度 (PSD)');
    xlabel(state.ax_spectrum, '频率 (kHz)');
    ylabel(state.ax_spectrum, '功率谱密度 (dB/Hz)');
    grid(state.ax_spectrum, 'on');
    state.ax_spectrum.XGrid = 'on';
    state.ax_spectrum.YGrid = 'on';
    state.ax_spectrum.Box = 'on';

    state.ax_waterfall = uiaxes(spec_grid);
    title(state.ax_waterfall, '瀑布图 (Spectrogram)');
    xlabel(state.ax_waterfall, '时间 (s)');
    ylabel(state.ax_waterfall, '频率 (kHz)');
    grid(state.ax_waterfall, 'on');
    state.ax_waterfall.Box = 'on';

    % Tab 2: 时域波形
    tab_time = uitab(tab_group, 'Title', '时域波形');
    time_grid = uigridlayout(tab_time, [2, 1]);
    time_grid.RowHeight = {'1x', '1x'};

    state.ax_iqwave = uiaxes(time_grid);
    title(state.ax_iqwave, 'IQ基带信号波形 (局部)');
    xlabel(state.ax_iqwave, '时间 (ms)');
    ylabel(state.ax_iqwave, '幅度');
    legend(state.ax_iqwave, {'I路', 'Q路'}, 'Location', 'best');
    grid(state.ax_iqwave, 'on');
    state.ax_iqwave.Box = 'on';

    state.ax_audio = uiaxes(time_grid);
    title(state.ax_audio, '解调后音频波形');
    xlabel(state.ax_audio, '时间 (s)');
    ylabel(state.ax_audio, '归一化幅度');
    grid(state.ax_audio, 'on');
    state.ax_audio.Box = 'on';

    % ---- 状态栏 ----
    bottom_grid = uigridlayout(main_grid, [1, 3]);
    bottom_grid.ColumnWidth = {'1x', 200, 180};
    bottom_grid.Padding = [6, 0, 6, 2];

    state.lbl_status = uilabel(bottom_grid, ...
        'Text', '就绪 - 请加载IQ基带数据文件', ...
        'FontColor', [0.2 0.2 0.2]);

    state.lbl_progress = uilabel(bottom_grid, ...
        'Text', '', 'HorizontalAlignment', 'right', ...
        'FontColor', [0.3 0.5 0.3]);

    state.lbl_mode = uilabel(bottom_grid, ...
        'Text', '模式: FM解调', ...
        'HorizontalAlignment', 'right', ...
        'FontWeight', 'bold', 'FontColor', [0.2 0.4 0.8]);

    %% ==================== 回调函数 ====================

    function load_file_callback()
        [fname, fpath] = uigetfile({'*.wav;*.iq;*.bin', ...
            'IQ基带数据文件 (*.wav, *.iq, *.bin)'; ...
            '*.*', '所有文件 (*.*)'}, ...
            '选择IQ基带数据文件');

        if fname == 0
            return;  % 用户取消
        end

        fullpath = fullfile(fpath, fname);
        state.filename = fullpath;
        state.lbl_status.Text = '正在读取文件...';
        drawnow;

        try
            [iq_data, fs_read, file_info] = read_iq_file(fullpath);

            state.iq_data = iq_data(:);  % 确保列向量
            state.fs = fs_read;
            state.is_loaded = true;

            % 更新UI
            [~, name, ext] = fileparts(fullpath);
            short_name = [name, ext];
            if length(short_name) > 30
                short_name = ['...', short_name(end-26:end)];
            end
            state.lbl_file.Text = ['文件: ', short_name];

            dur = length(state.iq_data) / state.fs;
            state.duration_sec = dur;
            state.file_size_mb = file_info.size_mb;

            info_str = sprintf(['采样率: %.3f MSPS\n时长: %.2f s\n', ...
                '采样点: %s\n文件大小: %.1f MB\n通道: %s\n位深: %d-bit'], ...
                state.fs/1e6, dur, ...
                format_number(length(state.iq_data)), ...
                file_info.size_mb, file_info.channels_str, file_info.bits);

            state.lbl_info.Text = info_str;
            state.edit_fs.Value = state.fs / 1e6;
            state.lbl_status.Text = sprintf('文件加载完成 - %s', short_name);
            state.lbl_status.FontColor = [0 0.6 0];

            % 快速显示频谱预览
            quick_spectrum_preview();

            state.btn_analyze.Enable = 'on';
            state.btn_play.Enable = 'off';
            state.btn_export.Enable = 'off';
            state.is_demod = false;

        catch ME
            state.lbl_status.Text = ['加载失败: ', ME.message];
            state.lbl_status.FontColor = [0.8 0 0];
            state.is_loaded = false;
        end
    end

    function analyze_callback()
        if ~state.is_loaded
            uialert(fig, '请先加载IQ数据文件', '提示');
            return;
        end

        % 读取解调模式
        if state.rb_fm.Value
            state.mode = 'FM';
        else
            state.mode = 'AM';
        end

        % 读取手动参数
        state.fs = state.edit_fs.Value * 1e6;
        state.fc = state.edit_fc.Value * 1e6;
        f_offset  = state.edit_fo.Value * 1e3;   % kHz -> Hz

        state.lbl_mode.Text = ['模式: ', state.mode, '解调'];
        state.lbl_status.Text = sprintf('正在%s解调...', state.mode);
        state.lbl_progress.Text = '处理中...';
        drawnow;

        try
            % --- 频谱分析 (显示全基带, 方便找信号峰值) ---
            plot_full_spectrum(state.ax_spectrum, state.iq_data, ...
                               state.fs, state.fc, state.mode);
            plot_spectrogram(state.ax_waterfall, state.iq_data, ...
                             state.fs, state.fc);

            % --- IQ时域波形 ---
            plot_iq_waveform(state.ax_iqwave, state.iq_data, state.fs);

            % --- 频道选择: 数字移频 + 滤波, 将目标信号搬到DC ---
            iq_selected = channel_select(state.iq_data, state.fs, ...
                                         f_offset, state.mode);

            % --- 解调 ---
            switch state.mode
                case 'AM'
                    state.audio = am_demodulate(iq_selected, ...
                                                state.fs, state.audio_fs);
                case 'FM'
                    state.audio = fm_demodulate(iq_selected, ...
                                                state.fs, state.audio_fs);
            end

            % --- 音频波形 ---
            plot_audio_waveform(state.ax_audio, state.audio, state.audio_fs);

            state.is_demod = true;
            state.btn_play.Enable = 'on';
            state.btn_export.Enable = 'on';
            state.lbl_status.Text = sprintf('%s解调完成 - 可播放或导出音频', ...
                                            state.mode);
            state.lbl_status.FontColor = [0 0.6 0];
            state.lbl_progress.Text = '完成';

        catch ME
            state.lbl_status.Text = ['分析失败: ', ME.message];
            state.lbl_status.FontColor = [0.8 0 0];
            state.lbl_progress.Text = '错误';
        end
    end

    function play_callback()
        if ~state.is_demod
            uialert(fig, '请先完成解调分析', '提示');
            return;
        end

        state.lbl_status.Text = '正在播放...';
        drawnow;

        try
            % 先停掉之前的播放, 避免多次点击叠加
            clear sound;
            % 归一化防止削波
            audio_out = state.audio / max(abs(state.audio)) * 0.9;
            sound(audio_out, state.audio_fs);
            state.lbl_status.Text = sprintf('播放中 - 时长 %.1f 秒', ...
                length(state.audio) / state.audio_fs);
        catch ME
            state.lbl_status.Text = ['播放失败: ', ME.message];
            state.lbl_status.FontColor = [0.8 0 0];
        end
    end

    function export_callback()
        if ~state.is_demod
            uialert(fig, '请先完成解调分析', '提示');
            return;
        end

        % 生成默认文件名
        [~, name, ~] = fileparts(state.filename);
        suggested = sprintf('%s_%s_demod.wav', name, state.mode);

        [fname, fpath] = uiputfile({'*.wav', 'WAV音频文件 (*.wav)'}, ...
            '导出解调音频', suggested);

        if fname == 0
            return;
        end

        try
            % 归一化到 [-1, 1]
            audio_out = state.audio / max(abs(state.audio));

            audiowrite(fullfile(fpath, fname), audio_out, state.audio_fs, ...
                'BitsPerSample', 16, ...
                'Comment', sprintf('SDR Offline %s Demodulation', state.mode));

            state.lbl_status.Text = ['已导出: ', fname];
            state.lbl_status.FontColor = [0 0.6 0];
        catch ME
            state.lbl_status.Text = ['导出失败: ', ME.message];
            state.lbl_status.FontColor = [0.8 0 0];
        end
    end

    %% ==================== 快速频谱预览 ====================
    function quick_spectrum_preview()
        % 加载文件后立即显示全频谱 + 信号检测标注
        if state.rb_fm.Value
            mode_str = 'FM';
        else
            mode_str = 'AM';
        end
        state.fc = state.edit_fc.Value * 1e6;
        state.fs = state.edit_fs.Value * 1e6;

        plot_full_spectrum(state.ax_spectrum, state.iq_data, ...
                           state.fs, state.fc, mode_str);

        % 同时显示 IQ 波形预览
        plot_iq_waveform(state.ax_iqwave, state.iq_data, state.fs);

        % 瀑布图预览
        plot_spectrogram(state.ax_waterfall, state.iq_data, ...
                         state.fs, state.fc);

        % 清空旧的音频波形
        cla(state.ax_audio);
        title(state.ax_audio, '解调后音频波形');
    end

    %% ==================== 模式切换响应 ====================
    mode_group.SelectionChangedFcn = @(src, evt) update_mode_display();

    function update_mode_display()
        if state.rb_fm.Value
            state.lbl_mode.Text = '模式: FM解调';
        else
            state.lbl_mode.Text = '模式: AM解调';
        end
        if state.is_loaded
            state.is_demod = false;
            state.btn_play.Enable = 'off';
            state.btn_export.Enable = 'off';
        end
    end

end  % sdr_offline_processor 主函数结束


%% ==================== IQ文件读取 ====================
function [iq_complex, fs, info] = read_iq_file(filename)
% 读取WAV/RF64格式的IQ基带数据文件
% 支持格式:
%   - WAV立体声 (I=左声道, Q=右声道)
%   - RF64立体声 (同上, 支持>4GB文件)
%   - 16-bit / 8-bit PCM
% 返回:
%   iq_complex - IQ复信号 (N×1 complex double)
%   fs         - 采样率 (Hz)
%   info       - 文件信息结构体

    [~, ~, ext] = fileparts(filename);

    % 获取文件大小
    file_info = dir(filename);
    info = struct();
    info.size_mb = file_info.bytes / (1024 * 1024);
    info.size_bytes = file_info.bytes;

    % 尝试 audioread (适用于标准WAV和大多数RF64文件)
    try
        [data, fs] = audioread(filename, 'native');

        % 处理不同的通道情况
        [~, nchannels] = size(data);

        if nchannels == 2
            % 标准立体声IQ: I=左(第2列), Q=右(第1列) 或反之
            % MATLAB audioread返回: 列1=左声道, 列2=右声道
            I = double(data(:, 1));
            Q = double(data(:, 2));
            info.channels_str = '立体声IQ';
            info.bits = 16;
        elseif nchannels == 1
            % 单声道: 假设为交织IQ
            I = double(data(1:2:end));
            Q = double(data(2:2:end));
            info.channels_str = '单声道(交织IQ)';
            info.bits = 16;
        else
            error('不支持的通道数: %d', nchannels);
        end

        iq_complex = I + 1j * Q;
        info.method = 'audioread';
        return;

    catch ME_audio
        % audioread 失败, 尝试手动解析WAV/RF64
        warning('SDR:FallbackParse', ...
            'audioread失败 (%s), 尝试手动解析WAV/RF64...', ME_audio.message);
    end

    % ------ 手动解析 WAV/RF64 ------
    fid = fopen(filename, 'rb');
    if fid == -1
        error('无法打开文件: %s', filename);
    end

    cleanup = onCleanup(@() fclose(fid));

    % 读取RIFF/RF64头
    chunk_id = char(fread(fid, 4, 'uchar')');
    fread(fid, 1, 'uint32');  % 跳过文件大小 (对于RF64可能为-1)

    if strcmp(chunk_id, 'RF64')
        % RF64格式: 跳过ds64 chunk
        wave_id = char(fread(fid, 4, 'uchar')');
        if ~strcmp(wave_id, 'WAVE')
            error('无效的RF64文件');
        end
        % 查找ds64 chunk并跳过
        ds64_id = char(fread(fid, 4, 'uchar')');
        if strcmp(ds64_id, 'ds64')
            ds64_size = fread(fid, 1, 'uint32');
            fseek(fid, ds64_size, 'cof');
        else
            fseek(fid, -4, 'cof');  % 回退，不是ds64
        end
    elseif ~strcmp(chunk_id, 'RIFF')
        error('不支持的文件格式, ChunkID: %s', chunk_id);
    else
        % 标准RIFF WAV
        wave_id = char(fread(fid, 4, 'uchar')');
        if ~strcmp(wave_id, 'WAVE')
            error('无效的WAV文件');
        end
    end

    % 解析fmt chunk
    fmt_found = false;
    fmt = struct();
    while ~feof(fid)
        subchunk_id = char(fread(fid, 4, 'uchar')');
        subchunk_size = fread(fid, 1, 'uint32');

        if strcmp(subchunk_id, 'fmt ')
            fmt.format_tag    = fread(fid, 1, 'uint16');
            fmt.num_channels  = fread(fid, 1, 'uint16');
            fmt.sample_rate   = fread(fid, 1, 'uint32');
            fmt.byte_rate     = fread(fid, 1, 'uint32');
            fmt.block_align   = fread(fid, 1, 'uint16');
            fmt.bits_per_sample = fread(fid, 1, 'uint16');

            % 跳过额外的fmt字节
            if subchunk_size > 16
                fseek(fid, subchunk_size - 16, 'cof');
            end
            fmt_found = true;
            break;
        else
            % 跳过未知chunk
            fseek(fid, subchunk_size, 'cof');
        end
    end

    if ~fmt_found
        error('未找到fmt chunk');
    end

    % 验证格式
    if fmt.format_tag ~= 1  % PCM
        error('仅支持PCM格式, 当前FormatTag: %d', fmt.format_tag);
    end

    % 查找data chunk
    data_found = false;
    fseek(fid, 0, 'bof');
    % 跳过RIFF头
    fread(fid, 4, 'uchar');
    riff_size = fread(fid, 1, 'uint32');
    fread(fid, 4, 'uchar');

    while ~feof(fid)
        subchunk_id = char(fread(fid, 4, 'uchar')');
        subchunk_size = fread(fid, 1, 'uint32');

        if strcmp(subchunk_id, 'data')
            data_found = true;
            break;
        else
            fseek(fid, subchunk_size, 'cof');
        end
    end

    if ~data_found
        error('未找到data chunk');
    end

    % 读取数据
    bytes_per_sample = fmt.bits_per_sample / 8;
    total_samples = subchunk_size / bytes_per_sample;

    if fmt.num_channels == 2
        raw_data = fread(fid, total_samples, 'int16');
        raw_data = reshape(raw_data, 2, [])';
        I = double(raw_data(:, 1));
        Q = double(raw_data(:, 2));
        info.channels_str = '立体声IQ';
    else
        raw_data = fread(fid, total_samples, 'int16');
        I = double(raw_data(1:2:end));
        Q = double(raw_data(2:2:end));
        info.channels_str = '交织IQ';
    end

    fs = fmt.sample_rate;
    info.bits = fmt.bits_per_sample;
    info.method = 'manual';

    iq_complex = I + 1j * Q;
end


%% ==================== AM解调 ====================
function audio = am_demodulate(iq, fs, audio_fs)
% AM包络检波解调
%   输入: iq      - IQ复基带信号
%         fs      - 基带采样率 (Hz)
%         audio_fs - 输出音频采样率 (Hz, 默认48000)
%   输出: audio   - 解调音频 (归一化到[-1,1])
%
%   算法:
%     1. 计算瞬时包络: env = |iq|
%     2. 去直流 (去除载波分量A0)
%     3. 低通滤波 (截止频率~5kHz)
%     4. 降采样到audio_fs
%     5. 幅度归一化

    % 1. 包络检波
    envelope = abs(iq);

    % 2. 去直流
    envelope = envelope - mean(envelope);

    % 3. 设计低通滤波器 (AM音频带宽约5kHz)
    lp_cutoff = 5000;   % AM音频截止频率
    lp_stop   = 6000;   % 阻带起始

    % 多级降采样，避免一次降采样倍数过大
    % 从 fs 逐级降到 audio_fs
    audio = multistage_decimate(envelope, fs, audio_fs, lp_cutoff);

    % 4. 归一化
    peak = max(abs(audio));
    if peak > 0
        audio = audio / peak;
    end
end


%% ==================== FM解调 ====================
function audio = fm_demodulate(iq, fs, audio_fs)
% FM正交鉴频解调
%   输入: iq      - IQ复基带信号
%         fs      - 基带采样率 (Hz)
%         audio_fs - 输出音频采样率 (Hz, 默认48000)
%   输出: audio   - 解调音频 (归一化到[-1,1])
%
%   算法:
%     1. 计算瞬时相位: phi = atan2(Q, I)
%     2. 相位解缠绕 (unwrap)
%     3. 差分求瞬时频率: freq = d(phi)/dt * (1/(2*pi))
%     4. 去直流 (消除频偏)
%     5. 低通滤波 (截止频率~15kHz for FM广播)
%     6. 降采样
%     7. 去加重 (50μs, 中国/欧洲标准)
%     8. 幅度归一化

    % 1. 计算瞬时相位
    phi = atan2(imag(iq), real(iq));

    % 2. 相位解缠绕
    phi_unwrapped = unwrap(phi);

    % 3. 差分求瞬时频率
    freq_inst = diff(phi_unwrapped) * fs / (2 * pi);
    freq_inst = [freq_inst(1); freq_inst];  % 保持与原信号等长

    % 4. 去直流 (消除载波频偏和DC offset)
    freq_inst = freq_inst - mean(freq_inst);

    % 5. 低通滤波 (FM音频带宽~15kHz)
    lp_cutoff = 15000;
    audio_raw = multistage_decimate(freq_inst, fs, audio_fs, lp_cutoff);

    % 6. 去加重 (50μs时间常数, 中国/欧洲FM广播标准)
    tau = 50e-6;
    alpha = exp(-1 / (audio_fs * tau));
    audio = filter(1 - alpha, [1, -alpha], audio_raw);

    % 7. 去直流 (去加重后可能引入微小DC偏置)
    audio = audio - mean(audio);

    % 8. 归一化
    peak = max(abs(audio));
    if peak > 0
        audio = audio / peak;
    end
end


%% ==================== 频道选择 (数字移频+滤波) ====================
function iq_out = channel_select(iq, fs, f_offset, mode)
% 基带内频道选择: 将目标信号从偏移处搬到DC, 并低通滤波隔离
%   iq       - 输入全基带IQ信号
%   fs       - 采样率 (Hz)
%   f_offset - 目标信号在基带中的频率偏移 (Hz)
%              正值 = 信号在DC右侧, 负值 = 信号在DC左侧
%   mode     - 'AM' 或 'FM', 决定滤波器带宽
%   iq_out   - 频道选择后的IQ信号 (目标信号已移至DC)

    N = length(iq);
    t = (0:N-1)' / fs;

    % 1. 数字下变频: 将目标信号从 f_offset 搬移到 0 Hz
    iq_shifted = iq .* exp(-1j * 2 * pi * f_offset * t);

    % 2. 低通滤波, 带宽根据调制方式选择
    switch upper(mode)
        case 'AM'
            bw_cutoff = 6000;   % AM广播信号带宽~10kHz, 保留±6kHz
        case 'FM'
            bw_cutoff = 120000; % FM广播信号带宽~200kHz, 保留±120kHz
    end

    % 设计抗混叠低通滤波器
    filt_stop = bw_cutoff * 1.15;
    try
        lp_filt = designfilt('lowpassfir', ...
            'PassbandFrequency', bw_cutoff, ...
            'StopbandFrequency', filt_stop, ...
            'PassbandRipple', 0.01, ...
            'StopbandAttenuation', 80, ...
            'SampleRate', fs, ...
            'DesignMethod', 'kaiserwin');
        iq_out = filter(lp_filt, iq_shifted);
    catch
        % fallback: 简单FIR
        N_fir = min(512, round(fs / bw_cutoff * 3));
        b = fir1(N_fir, bw_cutoff / (fs/2), 'low');
        iq_out = filter(b, 1, iq_shifted);
    end

    iq_out = iq_out(:);
end


%% ==================== 多级降采样 ====================
function y = multistage_decimate(x, fs_in, fs_out, lp_cutoff)
% 多级降采样，每级降采样因子不超过10，以获得更好的滤波效果
%   x         - 输入信号
%   fs_in     - 输入采样率
%   fs_out    - 输出采样率
%   lp_cutoff - 低通截止频率

    y = x;
    fs_current = fs_in;

    while fs_current > fs_out * 1.5
        % 确定当前级降采样因子 (不超过10)
        D = min(10, floor(fs_current / fs_out));
        if D < 2
            D = 2;
        end

        % 确保降采样后的采样率不低于目标
        if fs_current / D < fs_out
            D = round(fs_current / fs_out);
            if D < 2
                break;
            end
        end

        fs_new = fs_current / D;

        % 设计抗混叠低通滤波器
        filt_cutoff = min(lp_cutoff, fs_new * 0.45);
        filt_stop   = fs_new * 0.5;

        try
            fir_filt = designfilt('lowpassfir', ...
                'PassbandFrequency', filt_cutoff, ...
                'StopbandFrequency', filt_stop, ...
                'PassbandRipple', 0.01, ...
                'StopbandAttenuation', 80, ...
                'SampleRate', fs_current, ...
                'DesignMethod', 'kaiserwin');
            y = filter(fir_filt, y);
        catch
            % designfilt不可用时的fallback
            N = min(256, round(fs_current / filt_cutoff * 4));
            b = fir1(N, filt_cutoff / (fs_current / 2));
            y = filter(b, 1, y);
        end

        % 降采样
        y = y(1:D:end);
        fs_current = fs_new;
    end

    % 最后一级: 用resample精确调整到目标采样率
    if fs_current ~= fs_out
        y = resample(y, fs_out, round(fs_current));
    end

    % 确保列向量
    y = y(:);
end


%% ==================== 信号检测 ====================
function signals = detect_signals(f_centered, pxx_db, mode)
% 基于局部自适应噪声基底的信号检测
%   核心思路:
%     1. 移动窗口 15% 分位数 → 逐 bin 的局部噪声基底
%     2. 局部基底 + 偏移 → 逐 bin 自适应门限
%     3. 门限以上 → 二值化 → 闭运算桥接 → 连通域标记 → 质心估计
%   为什么不用全局门限: RTL-SDR 频率响应不平坦, 噪声基底随频率变化常 >10dB.
%     全局门限在低噪声区太高(漏信号), 在高噪声区太低(误检).
%
%   f_centered - 频率向量 (Hz, -fs/2 ~ +fs/2, 已 fftshift)
%   pxx_db     - PSD (dB, 已 fftshift)
%   mode       - 'AM' | 'FM'
%   signals    - 结构数组, 字段: .freq(Hz) .snr(dB) .bw(Hz) .peak_pwr(dB)

    df = f_centered(2) - f_centered(1);
    N  = length(pxx_db);

    % ---- 1. 模式参数 ----
    switch upper(mode)
        case 'FM'
            local_wnd   = 350e3;   % 局部噪声估计窗宽 (Hz)
            snr_margin  = 5.5;     % 高于局部基底的 dB 数
            min_bw      = 25e3;
            max_bw      = 320e3;
            gap_khz     = 10;      % 桥接间隙 (kHz)
        case 'AM'
            local_wnd   = 60e3;
            snr_margin  = 7;
            min_bw      = 2e3;
            max_bw      = 25e3;
            gap_khz     = 2;
    end

    % ---- 2. 局部噪声基底: 移动 15% 分位数 ----
    % 为什么 15%: 低于中位数, 对信号占空比更鲁棒.
    %   即使 50% 带宽被信号占据, 仍有 35% 纯噪声样本在 15% 分位线以下.
    half_bins = round(local_wnd / df / 2);
    half_bins = max(half_bins, 10);

    % 降采样计算, 然后插值到全分辨率
    step = max(1, round(half_bins / 3));
    sample_idx = [1:step:N, N];
    noise_samp = zeros(size(sample_idx));
    for i = 1:length(sample_idx)
        lo = max(1, sample_idx(i) - half_bins);
        hi = min(N, sample_idx(i) + half_bins);
        noise_samp(i) = prctile(pxx_db(lo:hi), 15);
    end
    noise_local = interp1(sample_idx, noise_samp, 1:N, 'pchip')';

    % ---- 3. 逐 bin 自适应门限 + 二值化 ----
    threshold = noise_local + snr_margin;
    above = pxx_db > threshold;

    % ---- 4. 屏蔽 DC 尖峰 (本振泄漏, ±500 Hz) ----
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

    % ---- 5. 形态学闭运算 (桥接窄缝: 导频音凹陷等) ----
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

    % ---- 6. 连通域标记 (手动实现) ----
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

    % ---- 7. 分析每个区域 (用局部噪声基底算 SNR) ----
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

        % 加权质心 (线性功率加权)
        p_lin = 10.^(p_reg / 10);
        fc_est = sum(f_reg .* p_lin) / sum(p_lin);

        % 用信号中心处的局部噪声基底计算 SNR (而非全局值)
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


%% ==================== 绘制完整频谱 ====================
function plot_full_spectrum(ax, iq, fs, fc, mode)
% 绘制完整功率谱密度图, 自动检测并标注信号

    cla(ax);

    % 对长数据进行分段平均
    N = length(iq);
    if N > 10e6
        n_seg = min(5e6, floor(N/4));
        iq_for_psd = [iq(1:n_seg); iq(end-n_seg+1:end)];
    else
        iq_for_psd = iq;
    end

    % 计算PSD
    [pxx, f] = pwelch(iq_for_psd, hann(8192), 4096, 16384, fs);
    pxx_db = fftshift(10 * log10(pxx));
    f_centered = f - fs/2;    % Hz, 从 -fs/2 到 +fs/2
    f_khz = f_centered / 1e3;

    % --- 自动检测信号 ---
    signals = detect_signals(f_centered, pxx_db, mode);

    % --- 绘制频谱 ---
    plot(ax, f_khz, pxx_db, 'b-', 'LineWidth', 1.0);
    hold(ax, 'on');

    % 标注模式带宽参考线
    switch upper(mode)
        case 'AM'
            bw_ref_khz = 10;
            ref_color = [1.0 0.3 0.1];
        case 'FM'
            bw_ref_khz = 200;
            ref_color = [0.1 0.4 1.0];
    end

    xline(ax, -bw_ref_khz/2, '--', 'Color', ref_color, 'LineWidth', 1.2);
    xline(ax, +bw_ref_khz/2, '--', 'Color', ref_color, 'LineWidth', 1.2);

    ylims_all = ylim(ax);

    % --- 标注检测到的信号 ---
    colors = lines(min(length(signals), 7));  % 不同颜色区分
    anno_lines = {};  % 收集标注文本

    for k = 1:length(signals)
        s = signals(k);
        color_k = colors(k, :);

        % 中心频率竖线
        xline(ax, s.freq/1e3, '-', 'Color', color_k, 'LineWidth', 1.5);

        % 带宽边界 (虚线)
        bw_half_khz = s.bw / 2e3;
        xline(ax, (s.freq - s.bw/2)/1e3, ':', 'Color', color_k, 'LineWidth', 0.8);
        xline(ax, (s.freq + s.bw/2)/1e3, ':', 'Color', color_k, 'LineWidth', 0.8);

        % 信号顶部文字标注
        text(ax, s.freq/1e3, s.peak_pwr + 2, ...
            sprintf('%.1f kHz', s.freq/1e3), ...
            'Color', color_k, 'FontSize', 9, 'FontWeight', 'bold', ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom');

        % 最强信号用星号标记
        marker_str = '';
        if k == 1
            marker_str = ' ← 最强';
        end
        anno_lines{end+1} = sprintf('  %+.1f kHz  SNR %.0f dB%s', ...
            s.freq/1e3, s.snr, marker_str);
    end

    % --- 右上角信息框 ---
    text_lines = {};
    if ~isempty(signals)
        % 多行文本: 用 cell array 保证可靠的换行 (兼容所有 MATLAB 版本)
        text_lines{1} = sprintf('[检测到 %d 个%s信号]', ...
            length(signals), upper(mode));
        for i = 1:length(anno_lines)
            text_lines{end+1} = anno_lines{i};
        end
        text_lines{end+1} = '';
        text_lines{end+1} = sprintf('噪声基底(全局中位数): %.0f dB/Hz', ...
            median(pxx_db));

        text(ax, 0.98, 0.98, text_lines, ...
            'Units', 'normalized', ...
            'FontSize', 9, 'FontName', 'Consolas', ...
            'BackgroundColor', [1 1 1 0.85], ...
            'EdgeColor', [0.3 0.3 0.3], ...
            'HorizontalAlignment', 'right', ...
            'VerticalAlignment', 'top', ...
            'Tag', 'DetectionInfo');
    else
        text(ax, 0.98, 0.98, ...
            {sprintf('未检测到%s信号', upper(mode)), ...
             '', ...
             sprintf('噪声基底(全局中位数): %.0f dB/Hz', median(pxx_db))}, ...
            'Units', 'normalized', ...
            'FontSize', 10, 'FontName', 'Consolas', ...
            'BackgroundColor', [1 1 0.8 0.85], ...
            'EdgeColor', [1 0.4 0], ...
            'HorizontalAlignment', 'right', ...
            'VerticalAlignment', 'top', ...
            'Tag', 'DetectionInfo');
    end

    hold(ax, 'off');

    xlabel(ax, '频率 (kHz)');
    ylabel(ax, '功率谱密度 (dB/Hz)');
    title(ax, sprintf('功率谱密度 (%s, Fc=%.2f MHz)', ...
          upper(mode), fc/1e6));
    grid(ax, 'on');
    xlim(ax, [-fs/2e3, fs/2e3]);
end


%% ==================== 绘制瀑布图 ====================
function plot_spectrogram(ax, iq, fs, fc)
% 绘制瀑布图: X轴=频率, Y轴=时间(最新在上), 颜色=功率(dB)
% 关键: 不抽取IQ数据(保持全带宽), 通过增大窗口跳步来控制时间帧数

    cla(ax);

    N = length(iq);
    target_frames = 400;
    window_len = 4096;
    nfft = 8192;

    if N <= window_len
        % 数据太短, 只取一帧
        start_indices = 1;
        target_frames = 1;
        window_len = N;
        nfft = 2^nextpow2(window_len);
    else
        % 均匀分布在全部数据上, 跨帧跳步 = N/target_frames
        start_indices = round(linspace(1, N - window_len, target_frames));
    end

    try
        win = hann(window_len);
        spec = zeros(nfft, target_frames);
        t_vec = zeros(1, target_frames);

        for i = 1:target_frames
            si = start_indices(i);
            chunk = iq(si : si + window_len - 1);
            spec(:, i) = fft(chunk .* win, nfft);
            t_vec(i) = (si + window_len / 2) / fs;  % 窗口中心时刻
        end

        % 转 dB, 频谱居中
        p_db = 10 * log10(abs(spec).^2 + eps);
        p_db = fftshift(p_db, 1);
        f_khz = ( (0:nfft-1)' / nfft * fs - fs/2 ) / 1e3;

        % 自适应颜色范围:
        %   c_low = 噪声基线上方 3dB → 噪声被压到最暗色, 不可见
        %   c_high = c_low + 38dB → 压缩动态, 信号颜色更饱满
        noise_ref = prctile(p_db(:), 10);
        c_low  = noise_ref + 3;
        c_high = c_low + 38;

        % 瀑布图: X=频率, Y=时间 (最新=顶部)
        imagesc(ax, f_khz, t_vec, p_db', [c_low, c_high]);
        set(ax, 'YDir', 'reverse');

        % 色图: turbo > parula > jet (优先使用感知均匀的色图)
        try
            colormap(ax, 'turbo');
        catch
            try
                colormap(ax, 'parula');
            catch
                colormap(ax, 'jet');
            end
        end

        % 坐标轴底色用深蓝黑, 让低功率区域"融入背景"
        set(ax, 'Color', [0.02 0.02 0.08]);

        cb = colorbar(ax);
        cb.Label.String = '功率 (dB/Hz)';

        xlabel(ax, '频率 (kHz)');
        ylabel(ax, '时间 (s)');
        title(ax, sprintf('瀑布图 (Fc=%.2f MHz)', fc/1e6));

    catch ME
        text(ax, 0.5, 0.5, ['瀑布图生成失败: ', ME.message], ...
            'HorizontalAlignment', 'center', 'FontSize', 10, ...
            'Color', [0.8 0 0]);
    end
end


%% ==================== 绘制IQ时域波形 ====================
function plot_iq_waveform(ax, iq, fs)
% 绘制IQ基带信号局部时域波形

    cla(ax);

    % 显示约10ms的数据
    n_show = min(length(iq), round(fs * 0.01));
    if n_show < 100
        n_show = min(length(iq), 1000);
    end

    t = (0:n_show-1)' / fs * 1e3;  % ms

    i_show = real(iq(1:n_show));
    q_show = imag(iq(1:n_show));

    plot(ax, t, i_show, 'b-', 'LineWidth', 0.5);
    hold(ax, 'on');
    plot(ax, t, q_show, 'r-', 'LineWidth', 0.5);
    hold(ax, 'off');

    xlabel(ax, '时间 (ms)');
    ylabel(ax, '幅度');
    title(ax, sprintf('IQ基带信号波形 (显示%.2f ms)', n_show/fs*1e3));
    legend(ax, {'I路', 'Q路'}, 'Location', 'best');
    grid(ax, 'on');
end


%% ==================== 绘制音频波形 ====================
function plot_audio_waveform(ax, audio, audio_fs)
% 绘制解调后的音频时域波形

    cla(ax);

    dur = length(audio) / audio_fs;
    t = (0:length(audio)-1)' / audio_fs;

    % 如果音频很长，先画概览，再画局部
    plot(ax, t, audio, 'b-', 'LineWidth', 0.3);
    xlabel(ax, '时间 (s)');
    ylabel(ax, '归一化幅度');
    title(ax, sprintf('解调音频波形 (总时长 %.1f s)', dur));
    grid(ax, 'on');
    xlim(ax, [0, dur]);
    ylim(ax, [-1.1, 1.1]);
end


%% ==================== 辅助工具函数 ====================
function s = format_number(n)
% 将大数字格式化为带单位的字符串
    if n >= 1e9
        s = sprintf('%.2f G', n/1e9);
    elseif n >= 1e6
        s = sprintf('%.2f M', n/1e6);
    elseif n >= 1e3
        s = sprintf('%.2f k', n/1e3);
    else
        s = sprintf('%d', n);
    end
end
