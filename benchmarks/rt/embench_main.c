/* Embench main for the pipelined core: one iteration, no timing hooks */
#include "support.h"
void initialise_board(void) {}
void start_trigger(void) {}
void stop_trigger(void) {}
int main(void)
{
    initialise_benchmark();
    int r = benchmark();
    return !verify_benchmark(r);
}
