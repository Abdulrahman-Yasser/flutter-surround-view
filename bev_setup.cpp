#include "bev_setup.h"

mat3 measured_H(const BevSlotConfig &slot, double px_per_m, int bev_w, int bev_h)
{
    const double r = px_per_m;
    mat3 S;
    S.at(0,0)= 1.0/r; S.at(0,1)= 0.0;   S.at(0,2)= -(bev_w/2.0)/r;
    S.at(1,0)= 0.0;   S.at(1,1)=-1.0/r; S.at(1,2)=  (bev_h/2.0)/r;
    S.at(2,0)= 0.0;   S.at(2,1)= 0.0;   S.at(2,2)= 1.0;

    mat3 H = slot.hb2i * S;
    for (int col = 0; col < 3; ++col) { H.at(0,col) /= slot.hb2i_w; H.at(1,col) /= slot.hb2i_h; }
    return H;
}

std::string lens_calib_path(const std::string &lens_dir, const std::string &lens_model)
{
    if (lens_dir.empty() || lens_dir.back() == '/') return lens_dir + lens_model + "-lens.ini";
    return lens_dir + "/" + lens_model + "-lens.ini";
}
