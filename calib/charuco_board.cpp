#include "charuco_board.h"

#if CV_VERSION_MAJOR > 4 || (CV_VERSION_MAJOR == 4 && CV_VERSION_MINOR >= 7)
#define CALIB_ARUCO_OBJDETECT 1
#include <opencv2/objdetect/aruco_detector.hpp>
#include <opencv2/objdetect/charuco_detector.hpp>
#else
#include <opencv2/aruco/charuco.hpp>
#endif

#include <numeric>
#include <stdexcept>
#include <string>

static int dict_id(const std::string &name)
{
    if (name == "ARUCO_ORIGINAL") return cv::aruco::DICT_ARUCO_ORIGINAL;
    static const int bits[] = {4, 5, 6, 7};
    static const int counts[] = {50, 100, 250, 1000};
    for (int b = 0; b < 4; ++b)
        for (int c = 0; c < 4; ++c)
            if (name == std::to_string(bits[b]) + "X" + std::to_string(bits[b]) + "_" + std::to_string(counts[c]))
                return b * 4 + c; // DICT_4X4_50 .. DICT_7X7_1000 are laid out this way
    throw std::runtime_error("unknown ArUco dictionary '" + name + "'");
}

struct CharucoModel::Impl {
#ifdef CALIB_ARUCO_OBJDETECT
    std::unique_ptr<cv::aruco::CharucoBoard> board;
#else
    cv::Ptr<cv::aruco::CharucoBoard> board;
#endif
};

CharucoModel::CharucoModel(const CalibBoard &cfg)
    : cfg_(cfg), dict_(dict_id(cfg.dict)), impl_(std::make_unique<Impl>())
{
    std::vector<int> ids(cfg.markers());
    std::iota(ids.begin(), ids.end(), cfg.first_id);
    std::vector<cv::Point3f> obj;
    cv::Point3f marker0;
#ifdef CALIB_ARUCO_OBJDETECT
    cv::aruco::Dictionary d = cv::aruco::getPredefinedDictionary(dict_);
    if (cfg.first_id + cfg.markers() > d.bytesList.rows)
        throw std::runtime_error("board ids exceed dictionary " + cfg.dict);
    impl_->board = std::make_unique<cv::aruco::CharucoBoard>(
        cv::Size(cfg.squares_x, cfg.squares_y), (float)cfg.square_len, (float)cfg.marker_len, d, ids);
    impl_->board->setLegacyPattern(cfg.legacy);
    obj = impl_->board->getChessboardCorners();
    marker0 = impl_->board->getObjPoints()[0][0];
#else
    cv::Ptr<cv::aruco::Dictionary> d = cv::aruco::getPredefinedDictionary(dict_);
    if (cfg.first_id + cfg.markers() > d->bytesList.rows)
        throw std::runtime_error("board ids exceed dictionary " + cfg.dict);
    if (!cfg.legacy)
        throw std::runtime_error("this OpenCV only knows the legacy ChArUco pattern");
    impl_->board = cv::aruco::CharucoBoard::create(cfg.squares_x, cfg.squares_y,
                                                   (float)cfg.square_len, (float)cfg.marker_len, d);
    impl_->board->ids = ids;
    obj = impl_->board->chessboardCorners;
    marker0 = impl_->board->objPoints[0][0];
#endif
    // OpenCV < 4.6 puts the board origin bottom-left with +y up; newer
    // releases put it top-left with +y down. Marker first_id is always on the
    // printed top row, so its position tells which one this build uses.
    const double h = cfg.squares_y * cfg.square_len;
    y_up_ = marker0.y > h / 2;
    for (const cv::Point3f &p : obj)
        corners_.emplace_back(p.x, y_up_ ? h - p.y : p.y);
}

CharucoModel::~CharucoModel() = default;

std::vector<std::pair<int, cv::Point2d>> CharucoModel::marker_centres() const
{
#ifdef CALIB_ARUCO_OBJDETECT
    const auto &obj = impl_->board->getObjPoints();
    const auto &ids = impl_->board->getIds();
#else
    const auto &obj = impl_->board->objPoints;
    const auto &ids = impl_->board->ids;
#endif
    const double h = cfg_.squares_y * cfg_.square_len;
    std::vector<std::pair<int, cv::Point2d>> out;
    for (size_t i = 0; i < obj.size() && i < ids.size(); ++i) {
        cv::Point2d c(0, 0);
        for (const cv::Point3f &p : obj[i]) c += cv::Point2d(p.x, p.y) * 0.25;
        out.emplace_back(ids[i], cv::Point2d(c.x, y_up_ ? h - c.y : c.y));
    }
    return out;
}

cv::Mat CharucoModel::draw(cv::Size size) const
{
    cv::Mat img;
#ifdef CALIB_ARUCO_OBJDETECT
    impl_->board->generateImage(size, img, 0, 1);
#else
    impl_->board->draw(size, img, 0, 1);
#endif
    return img;
}

ArucoMarkers CharucoModel::detect_markers(const cv::Mat &gray, int dict)
{
    ArucoMarkers m;
#ifdef CALIB_ARUCO_OBJDETECT
    cv::aruco::ArucoDetector det(cv::aruco::getPredefinedDictionary(dict));
    det.detectMarkers(gray, m.corners, m.ids);
#else
    cv::aruco::detectMarkers(gray, cv::aruco::getPredefinedDictionary(dict), m.corners, m.ids);
#endif
    return m;
}

void CharucoModel::interpolate(const cv::Mat &gray, const ArucoMarkers &all,
                               std::vector<cv::Point2f> &corners, std::vector<int> &ids) const
{
    corners.clear();
    ids.clear();
    std::vector<std::vector<cv::Point2f>> mc;
    std::vector<int> mid;
    for (size_t i = 0; i < all.ids.size(); ++i) {
        int id = all.ids[i];
        if (id >= cfg_.first_id && id < cfg_.first_id + cfg_.markers()) {
            mc.push_back(all.corners[i]);
            mid.push_back(id);
        }
    }
    if (mid.empty()) return;
#ifdef CALIB_ARUCO_OBJDETECT
    cv::aruco::CharucoDetector(*impl_->board).detectBoard(gray, corners, ids, mc, mid);
#else
    cv::aruco::interpolateCornersCharuco(mc, mid, gray, impl_->board, corners, ids);
#endif
}
