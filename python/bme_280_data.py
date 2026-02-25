import struct
import matplotlib.pyplot as plt

# ==============================
# PASTE Hex DATA
# ==============================
hex_data = """
FEC96D356732009F8D41D6D00BE71F0600F9FFAC260AD8BD104B7001001320031E
FF7F3E005D910076DA
FF7F48005D930076D6
FF7F4B005D930076DA
FF7F4F005D930076E0
FF7F51005D940076E4
FF7F53005D920076F0
FF7F54005D950076FF
FF7F56005D95007710
FF7F58005D96007718
FF7F57005D96007717
FF7F58005D93007704
FF7F5B005D950076F2
FF7F59005D930076DB
FF7F5E005D950076C3
FF7F5C005D960076B3
FF7F5D005D980076A7
FF7F5F005D970076A5
FF7F5E005D960076A8
FF7F5E005D940076A9
FF7F5F005D980076AA
FF7F60005D950076A8
FF7F61005D990076A4
FF7F62005D9600769D
FF7F63005D970076A2
FF7F62005D99007695
FF7F63005D96007692
FF7F62005D9700768E
FF7F62005D9A007691
FF7F63005D98007697
FF7F63005D96007694
FF7F64005D99007695
FF7F65005D98007693
FF7F65005D99007699
FF7F67005D980076A7
FF7F67005D960076D4
FF7F68005D9A0076F0
FF7F67005D9800770C
FF7F69005D9A00772A
FF7F69005D9A00773D
FF7F6B005D99007744
FF7F69005D99007751
"""




# Hex string -> byte array
data = bytes.fromhex(hex_data)

# ==============================
# 1) DEBUG CALIBRATION
# ==============================

if data[0] != 0xFE:
    raise ValueError("Calibration start is not FE.")

calib = data[1:33]   # 32 byte

def u16(lsb, msb):
    return (msb << 8) | lsb

def s16(lsb, msb):
    val = (msb << 8) | lsb
    if val & 0x8000:
        val -= 65536
    return val

dig_T1 = u16(calib[0], calib[1])
dig_T2 = s16(calib[2], calib[3])
dig_T3 = s16(calib[4], calib[5])

dig_P1 = u16(calib[6], calib[7])
dig_P2 = s16(calib[8], calib[9])
dig_P3 = s16(calib[10], calib[11])
dig_P4 = s16(calib[12], calib[13])
dig_P5 = s16(calib[14], calib[15])
dig_P6 = s16(calib[16], calib[17])
dig_P7 = s16(calib[18], calib[19])
dig_P8 = s16(calib[20], calib[21])
dig_P9 = s16(calib[22], calib[23])

dig_H1 = calib[24]
dig_H2 = s16(calib[25], calib[26])
dig_H3 = calib[27]
dig_H4 = (calib[28] << 4) | (calib[29] & 0x0F)
dig_H5 = (calib[30] << 4) | (calib[29] >> 4)
dig_H6 = struct.unpack("b", bytes([calib[31]]))[0]

print("Calibration loaded.")

# ==============================
# 2) FRAME ANALYSIS
# ==============================

frames = data[33:]

temperatures = []
pressures = []
humidities = []

i = 0
while i + 8 < len(frames):
    if frames[i] != 0xFF:
        i += 1
        continue

    adc_T = (frames[i+1] << 12) | (frames[i+2] << 4) | (frames[i+3] >> 4)
    adc_P = (frames[i+4] << 12) | (frames[i+5] << 4) | (frames[i+6] >> 4)
    adc_H = (frames[i+7] << 8) | frames[i+8]

    # ---- temperature calculator ----
    var1 = (((adc_T >> 3) - (dig_T1 << 1)) * dig_T2) >> 11
    var2 = (((((adc_T >> 4) - dig_T1) * ((adc_T >> 4) - dig_T1)) >> 12) * dig_T3) >> 14
    t_fine = var1 + var2
    T = (t_fine * 5 + 128) >> 8
    temperature = T / 100.0

    # ---- pressure calculator ----
    var1 = t_fine - 128000
    var2 = var1 * var1 * dig_P6
    var2 = var2 + ((var1 * dig_P5) << 17)
    var2 = var2 + (dig_P4 << 35)
    var1 = ((var1 * var1 * dig_P3) >> 8) + ((var1 * dig_P2) << 12)
    var1 = (((1 << 47) + var1) * dig_P1) >> 33

    if var1 != 0:
        p = 1048576 - adc_P
        p = (((p << 31) - var2) * 3125) // var1
        var1 = (dig_P9 * (p >> 13) * (p >> 13)) >> 25
        var2 = (dig_P8 * p) >> 19
        p = ((p + var1 + var2) >> 8) + (dig_P7 << 4)
        pressure = p / 25600.0
    else:
        pressure = 0

    # ---- humidity calculator ----
    v_x1 = t_fine - 76800
    v_x1 = (((((adc_H << 14) - (dig_H4 << 20) - (dig_H5 * v_x1)) + 16384) >> 15) *
           (((((((v_x1 * dig_H6) >> 10) * (((v_x1 * dig_H3) >> 11) + 32768)) >> 10) + 2097152)
           * dig_H2 + 8192) >> 14))
    v_x1 = v_x1 - (((((v_x1 >> 15) * (v_x1 >> 15)) >> 7) * dig_H1) >> 4)
    v_x1 = max(0, min(v_x1, 419430400))
    humidity = (v_x1 >> 12) / 1024.0

    temperatures.append(temperature)
    pressures.append(pressure)
    humidities.append(humidity)

    i += 9

# ==============================
# 3) RESULTS
# ==============================

for idx in range(len(temperatures)):
    print(f"{idx:03d} | {temperatures[idx]:.2f} °C | "
          f"{pressures[idx]:.2f} hPa | "
          f"{humidities[idx]:.2f} %RH")

# ==============================
# 4) CHART
# ==============================
# 
plt.figure()
plt.plot(temperatures)
plt.title("Temperature (°C)")
plt.show()
# 
plt.figure()
plt.plot(pressures)
plt.title("Pressure (hPa)")
plt.show()
# 
plt.figure()
plt.plot(humidities)
plt.title("Humidity (%RH)")
plt.show()
