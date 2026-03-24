clc; clear; close all;

%% ==========================================================
%% 1. 系统参数设置
%% ==========================================================
R_total = 8;        % 总插值因子
R_cfir  = 2;        % CFIR 承担 2倍
R_cic   = R_total / R_cfir; % CIC 承担剩余 4倍 (CIC在CFIR后面)

M = 1;              % 微分延迟
N = 3;              % CIC 级数
L_taps = 21;        % CFIR 阶数 (建议奇数)
Bit_Width = 16;     % 量化位宽

% 采样率 (仅作标尺)
Fs_in = 1e6;             
Fs_cfir_out = Fs_in * R_cfir; 

%% ==========================================================
%% 2. 计算 CIC 衰减曲线 (直观物理版)
%% ==========================================================
num_points = 2048;
f = linspace(0, 1, num_points); % 1.0 对应 CFIR 输出的 Nyquist

% --- [核心修改: 拒绝绕弯，物理直译] ---
% 目标：我们需要计算物理频率占 CIC 采样率的比例 (F_phy / Fs_cic)
% 步骤 1: 将 MATLAB 的归一化 f (以 Nyquist 为 1) 还原为 (以采样率为 1)
%         原因：Nyquist 是采样率的一半，所以要 * 0.5
ratio_to_cfir_fs = f * 0.5;

% 步骤 2: 映射到 CIC 的速率域
%         原因：CIC 的采样率是 CFIR 的 R_cic 倍，所以比例要除以 R_cic
ratio_to_cic_fs = ratio_to_cfir_fs / R_cic;

% 计算 CIC 幅频响应
% 注意：这里的 sin(pi * x) 中的 x 现在直接就是“相对于采样率的比例”，物理意义清晰
H_cic_mag = abs( sin(pi * M * R_cic * ratio_to_cic_fs) ./ ...
                 (R_cic * sin(pi * ratio_to_cic_fs) + eps) ).^N;
H_cic_mag(1) = 1;

%% ==========================================================
%% 3. 构建 CFIR 目标 (防止增益过大)
%% ==========================================================
H_ideal_cfir = 1 ./ H_cic_mag;

% 归一化频率点 (相对于 CFIR Nyquist)
input_nyquist_norm = 1.0 / R_cfir; % = 0.5

% 设置通带 (0.9 * Nyquist) 和 阻带 (1.0 * Nyquist)
fp_norm = 0.9 * input_nyquist_norm; 
fs_norm = 1.0 * input_nyquist_norm; 

idx_fp = find(f <= fp_norm, 1, 'last');

% 构建目标向量: 阻带给 0
freq_grid = [f(1:idx_fp), fs_norm, 1]; 
mag_grid  = [H_ideal_cfir(1:idx_fp), 0, 0]; 

%% ==========================================================
%% 4. 生成系数与自动防溢出缩放
%% ==========================================================
h_cfir_float = fir2(L_taps-1, freq_grid, mag_grid);

% --- 自动计算最大缩放因子 ---
max_val = max(abs(h_cfir_float));

% 如果系数本身大于1，必须缩小，否则定点化会溢出
shift_bits = 0;
h_cfir_scaled = h_cfir_float;

if max_val >= 1
    shift_bits = ceil(log2(max_val * 1.05)); % 1.05 是安全余量
    h_cfir_scaled = h_cfir_float / (2^shift_bits);
    fprintf('---------------------------------------------------\n');
    fprintf('警告：原始系数增益过大 (%f)，已自动缩小 %d 倍。\n', max_val, 2^shift_bits);
    fprintf('FPGA 操作指南：乘法结果请 **左移 %d 位** (<<< %d) 以恢复幅度。\n', shift_bits, shift_bits);
    fprintf('---------------------------------------------------\n');
end

% 定点化
Max_Int = 2^(Bit_Width-1) - 1;
h_cfir_quant = round(h_cfir_scaled * Max_Int);

%% ==========================================================
%% 5. 打印系数
%% ==========================================================
fprintf('\n// ===============================================\n');
fprintf('// CFIR Coefficients (16-bit Signed Hex)\n');
fprintf('// Scaling: Output has been scaled down by 2^%d.\n', shift_bits);
fprintf('// Recovery: Please LEFT SHIFT result by %d bits.\n', shift_bits);
fprintf('// ===============================================\n');

fprintf('// Hex Format for .coe or Verilog:\n');
for i = 1:length(h_cfir_quant)
    val = h_cfir_quant(i);
    if val < 0
        val = val + 65536; 
    end
    fprintf('16''h%04X, ', val);
    if mod(i,8)==0; fprintf('\n'); end
end
fprintf('\n\n// Decimal Format:\n{');
fprintf('%d, ', h_cfir_quant(1:end-1));
fprintf('%d};\n', h_cfir_quant(end));

%% ==========================================================
%% 6. 验证绘图 (保持逻辑一致)
%% ==========================================================
% 恢复增益看波形
H_actual_float = h_cfir_quant / Max_Int * (2^shift_bits); 

[H_actual, w] = freqz(H_actual_float, 1, 1024); 

% 这里的 w 是 0~pi，为了画图方便，我们转成 MATLAB 标准的归一化频率 (0~1)
w_norm_nyq = w/pi; 

% --- [验证部分的同步修改] ---
% 同样使用“相对于采样率”的逻辑来计算参考线
ratio_to_cic_fs_ref = (w_norm_nyq * 0.5) / R_cic;%乘以0.5是切换到相对于fs，除以R_cic是用来从cfir变换到cic的fs

H_cic_ref = abs( sin(pi * M * R_cic * ratio_to_cic_fs_ref) ./ ...
                 (R_cic * sin(pi * ratio_to_cic_fs_ref) + eps) ).^N;

figure;
subplot(2,1,1);
plot(w_norm_nyq, 20*log10(abs(H_actual)), 'b', 'LineWidth', 1.5); hold on;
plot(w_norm_nyq, 20*log10(H_cic_ref), 'r--', 'LineWidth', 1.5);
legend('CFIR Response', 'CIC Droop');
title(['补偿效果 (输入Nyquist=' num2str(input_nyquist_norm) ')']); 
grid on; xlim([0 0.6]); 
ylabel('Magnitude (dB)');

subplot(2,1,2);
plot(w_norm_nyq, 20*log10(abs(H_actual) .* H_cic_ref), 'k', 'LineWidth', 2);
title(['总响应 (理论平坦度) - 需 FPGA 左移 ' num2str(shift_bits) ' 位']);
grid on; xlim([0 0.6]); ylim([-2 2]);
xline(input_nyquist_norm, 'g--', 'Label', 'Input Nyquist');
xlabel('Normalized Frequency (1.0 = CFIR Nyquist)'); ylabel('Magnitude (dB)');