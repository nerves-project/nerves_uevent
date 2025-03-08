// SPDX-FileCopyrightText: 2022 Frank Hunleth
//
// SPDX-License-Identifier: Apache-2.0

#ifdef DEBUG
#include <stdio.h>
#include <stdlib.h>
#endif

#ifndef UTIL_H
#define UTIL_H

#ifdef DEBUG
FILE *log_location;
#define LOG_LOCATION log_location
#define debug(...) do { fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\r\n"); fflush(stderr); } while(0)
#else
#define LOG_LOCATION stderr
#define debug(...) do {} while(0)
#endif

#endif // UTIL_H
