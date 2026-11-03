/* runs Dhrystone and checks the final values it would print against "should be" */
#include <string.h>
#include "dhrystone.h"
extern Rec_Pointer Ptr_Glob;
extern int Int_Glob, Arr_1_Glob[50], Arr_2_Glob[50][50];
extern Boolean Bool_Glob;
extern char Ch_1_Glob, Ch_2_Glob;
int dhry_main(void);
int main(void)
{
    dhry_main();
    if (Int_Glob != 5) return 1;
    if (Bool_Glob != 1) return 2;
    if (Ch_1_Glob != 'A' || Ch_2_Glob != 'B') return 3;
    if (Arr_1_Glob[8] != 7) return 4;
    if (Arr_2_Glob[8][7] != NUMBER_OF_RUNS + 10) return 5;
    if (Ptr_Glob->Discr != 0 || Ptr_Glob->variant.var_1.Enum_Comp != 2 || Ptr_Glob->variant.var_1.Int_Comp != 17) return 6;
    if (strcmp(Ptr_Glob->variant.var_1.Str_Comp, "DHRYSTONE PROGRAM, SOME STRING")) return 7;
    return 0;
}
