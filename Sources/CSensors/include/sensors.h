#ifndef CSENSORS_H
#define CSENSORS_H

typedef struct {
    char name[64];
    double value;
} hw_temp_t;

/// Fills `out` with every temperature sensor exposed through the HID event
/// system (no root needed). Returns how many entries were written.
int hw_read_temperatures(hw_temp_t *out, int max);

typedef struct {
    double cpu_avg;   ///< mean of the per-core sensors
    double cpu_max;   ///< hottest CPU sensor, hot spots included (what macOS throttles on)
    double gpu_avg;   ///< mean of GPU sensors, 0 if none
} hw_chip_temps_t;

/// Reads CPU/GPU core temperatures from the SMC (Tp*/Te* = performance and
/// efficiency cores, Tg* = GPU). Returns 0 on success, -1 if unavailable.
int hw_read_chip_temps(hw_chip_temps_t *out);

/// macOS thermal pressure: 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping.
/// Returns -1 if unavailable.
int hw_thermal_pressure(void);

#endif
