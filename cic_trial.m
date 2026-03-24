clc; clear; close all;

%% ==========================================================
%% 1. 系统参数与双音测试信号生成
%% ==========================================================
Fs_in = 1e6;          % 输入低速采样率 1 MHz
R_cic = 8;            % 插值倍数 8 倍
Fs_out = Fs_in * R_cic; % 输出高速采样率 8 MHz
N = 3;                % 级联级数 3 级
M = 1;                % 差分延迟因子

% 生成测试信号：50kHz(低频) + 350kHz(高频，接近 Nyquist)
% 用双音信号可以完美在频域看出高频衰减(平坦度恶化)
t_in = 0 : 1/Fs_in : 0.002; 
x_in = 0.5*sin(2*pi*50e3*t_in) + 0.5*sin(2*pi*350e3*t_in);

%% ==========================================================
%% 2. 纯手工模拟 FPGA 硬件架构 (无 filter 函数)
%% ==========================================================

% -----------------------------------------------------------
% [架构级 1] : 梳状级 (Comb) - 运行在低速 Fs_in
% 硬件映射：N个减法器 + N个寄存器
% -----------------------------------------------------------
c_out = x_in;
comb_regs = zeros(N, 1); % 模拟 N 级的 D触发器 (存上一个值)

for k = 1:N
    c_in = c_out;
    for n = 1:length(c_in)
        % 硬件减法器逻辑: Output = Input - Last_Input
        c_out(n) = c_in(n) - comb_regs(k);
        % 硬件寄存器更新 (DFF 打一拍)
        comb_regs(k) = c_in(n); 
    end
end

% -----------------------------------------------------------
% [架构级 2] : 升采样 (Zero-Stuffer)
% 硬件映射：使能控制逻辑，1个有效数据带 7个0
% -----------------------------------------------------------
x_up = zeros(1, length(c_out) * R_cic);
x_up(1:R_cic:end) = c_out; 

% -----------------------------------------------------------
% [架构级 3] : 积分级 (Integrator) - 运行在高速 Fs_out
% 硬件映射：N个加法器 + N个反馈寄存器 (无限累加)
% -----------------------------------------------------------
i_out = x_up;
integ_regs = zeros(N, 1); % 模拟 N 级的累加寄存器

for k = 1:N
    i_in = i_out;
    for n = 1:length(i_in)
        % 硬件加法器逻辑: Output = Input + Last_Output
        i_out(n) = i_in(n) + integ_regs(k);
        % 硬件寄存器更新 (DFF 打一拍反馈)
        integ_regs(k) = i_out(n); 
    end
end

% CIC 插值的理论幅度增益为 R^(N-1)，这里做除法模拟 FPGA 的截位(Shift)
x_final = i_out / (R_cic^(N-1));

%% ==========================================================
%% 3. 结果评估与绘图 (时域与频域平坦度分析)
%% ==========================================================

% --- 频域功率谱密度 (PSD) 计算 ---
[P_in, F_in_axis] = pwelch(x_in, rectwin(length(x_in)), 0, 4096, Fs_in);
[P_out, F_out_axis] = pwelch(x_final, rectwin(length(x_final)), 0, 4096, Fs_out);

P_in_dB = 10*log10(P_in);
P_out_dB = 10*log10(P_out);

% --- 提取两个单音点的增益 ---
% 找到 50kHz 和 350kHz 在输出频谱中的索引
[~, idx_50k] = min(abs(F_out_axis - 50e3));
[~, idx_350k] = min(abs(F_out_axis - 350e3));
gain_diff = P_out_dB(idx_50k) - P_out_dB(idx_350k); % 计算滚降衰减

% --- 绘图 ---
figure('Color', 'w', 'Position', [100 100 1200 600]);

% 1. 时域对比 (截取前50个低速点对应的时间)
subplot(2,2,[1 2]);
stem(t_in(1:50)*1e6, x_in(1:50), 'r', 'LineWidth', 1.5, 'MarkerSize', 6); hold on;
t_out = 0 : 1/Fs_out : (length(x_final)-1)/Fs_out;
plot(t_out(1:50*R_cic)*1e6, x_final(1:50*R_cic), 'b', 'LineWidth', 1.5);
grid on; xlabel('Time (\mu s)'); ylabel('Amplitude');
legend('原始输入 (离散点)', 'CIC 插值后 (阶梯平滑波形)');
title('时域重构: 从梳状差分到无限累加的奇迹');

% 2. 输入频谱
subplot(2,2,3);
plot(F_in_axis/1e3, P_in_dB, 'r', 'LineWidth', 1.5);
grid on; xlabel('Frequency (kHz)'); ylabel('Magnitude (dB)');
title('原始双音信号频谱 (输入域)'); xlim([0 500]); ylim([-100 10]);

% 3. 输出频谱与平坦度评估
subplot(2,2,4);
plot(F_out_axis/1e3, P_out_dB, 'b', 'LineWidth', 1.5); hold on;
plot(50, P_out_dB(idx_50k), 'ko', 'MarkerSize', 8, 'MarkerFaceColor', 'g');
plot(350, P_out_dB(idx_350k), 'ko', 'MarkerSize', 8, 'MarkerFaceColor', 'y');
grid on; xlabel('Frequency (kHz)'); ylabel('Magnitude (dB)');
title(['输出频谱 (8MHz) - 频域平坦度评估']);
xlim([0 1000]); ylim([-100 10]);
text(400, -20, sprintf('← 350kHz 处衰减了 %.2f dB !!\n(这就是为什么需要 CFIR 补偿)', gain_diff), ...
    'Color', 'red', 'FontWeight', 'bold', 'BackgroundColor', 'w');