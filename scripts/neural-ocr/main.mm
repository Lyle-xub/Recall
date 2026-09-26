// Local PP-OCRv6 pipeline. Pre/post-processing follows PaddleOCR/RapidOCR (Apache-2.0).
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <CommonCrypto/CommonDigest.h>
#include <onnxruntime_cxx_api.h>
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <fstream>
#include <iostream>
#include <sstream>
#include <map>
#include <deque>
#include <numeric>
#include <chrono>

static std::string hashMat(const cv::Mat& m) {
    cv::Mat continuous=m.isContinuous()?m:m.clone();unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(continuous.data,(CC_LONG)(continuous.total()*continuous.elemSize()),digest);
    static const char h[]="0123456789abcdef";std::string s=std::to_string(m.cols)+"x"+std::to_string(m.rows)+":";
    for(auto x:digest){s+=h[x>>4];s+=h[x&15];}return s;
}
static cv::Mat readImage(NSString* path) {
    NSURL* url=[NSURL fileURLWithPath:path];CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,nullptr);
    if(!source)throw std::runtime_error("Unreadable screenshot");
    NSDictionary* props=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,nullptr));
    long w=[props[(__bridge NSString*)kCGImagePropertyPixelWidth] longValue],h=[props[(__bridge NSString*)kCGImagePropertyPixelHeight] longValue];
    if(w<=0||h<=0||w*h>40000000){CFRelease(source);throw std::runtime_error("Invalid dimensions");}
    CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,nullptr);CFRelease(source);if(!image)throw std::runtime_error("Cannot decode screenshot");
    cv::Mat rgba((int)h,(int)w,CV_8UC4);CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(rgba.data,w,h,8,rgba.step,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);if(!context){CGImageRelease(image);throw std::runtime_error("Cannot decode pixels");}
    CGContextDrawImage(context,CGRectMake(0,0,w,h),image);CGContextRelease(context);CGImageRelease(image);
    cv::Mat bgr;cv::cvtColor(rgba,bgr,cv::COLOR_RGBA2BGR);return bgr;
}
struct Decode {std::string text;float score;};
class Engine {
    Ort::Env env{ORT_LOGGING_LEVEL_ERROR,"RecallOCR"};Ort::SessionOptions options;
    Ort::Session det{nullptr},rec{nullptr};Ort::AllocatorWithDefaultOptions allocator;
    std::string detIn,detOut,recIn,recOut;std::vector<std::string> characters;
    std::map<std::string,Decode> cache;std::deque<std::string> order;
    std::vector<float> tensor(const cv::Mat& image,int width,int height) {
        cv::Mat resized;cv::resize(image,resized,cv::Size(width,height));std::vector<float> values((size_t)3*width*height);
        for(int y=0;y<height;++y)for(int x=0;x<width;++x)for(int c=0;c<3;++c) values[(size_t)c*width*height+y*width+x]=resized.at<cv::Vec3b>(y,x)[c]/127.5f-1.f;
        return values;
    }
    Ort::Value run(Ort::Session& model,const std::string& in,const std::string& out,std::vector<float>& values,int width,int height) {
        std::array<int64_t,4> shape={1,3,height,width};auto memory=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);
        auto input=Ort::Value::CreateTensor<float>(memory,values.data(),values.size(),shape.data(),shape.size());
        const char* inputs[]={in.c_str()},*outputs[]={out.c_str()};auto result=model.Run(Ort::RunOptions{nullptr},inputs,&input,1,outputs,1);return std::move(result[0]);
    }
public:
    explicit Engine(const std::string& root) {
        // Leave cores available for WindowServer, capture and foreground apps.
        // Thread count changes scheduling only, not models or input resolution.
        cv::setNumThreads(1);options.SetIntraOpNumThreads(2);options.SetInterOpNumThreads(1);
        options.DisableCpuMemArena();options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        options.AddConfigEntry("session.intra_op.allow_spinning","0");options.AddConfigEntry("session.inter_op.allow_spinning","0");
        det=Ort::Session(env,(root+"/det.onnx").c_str(),options);rec=Ort::Session(env,(root+"/rec.onnx").c_str(),options);
        detIn=det.GetInputNameAllocated(0,allocator).get();detOut=det.GetOutputNameAllocated(0,allocator).get();
        recIn=rec.GetInputNameAllocated(0,allocator).get();recOut=rec.GetOutputNameAllocated(0,allocator).get();
        auto dictionary=rec.GetModelMetadata().LookupCustomMetadataMapAllocated("character",allocator);
        if(!dictionary)throw std::runtime_error("Missing model dictionary");
        characters.push_back("");std::istringstream stream(dictionary.get());std::string line;
        while(std::getline(stream,line)){if(!line.empty()&&line.back()=='\r')line.pop_back();characters.push_back(line);}characters.push_back(" ");
    }
    Decode recognize(const cv::Mat& crop,bool& cached) {
        auto key=hashMat(crop);auto found=cache.find(key);if(found!=cache.end()){cached=true;return found->second;}cached=false;
        int width=std::max(32,std::min(4096,(int)std::ceil(crop.cols*48.0/crop.rows)));
        auto values=tensor(crop,width,48);auto prediction=run(rec,recIn,recOut,values,width,48);
        auto shape=prediction.GetTensorTypeAndShapeInfo().GetShape();if(shape.size()!=3||shape[2]!=(int64_t)characters.size())throw std::runtime_error("Unexpected recognition output");
        auto scores=prediction.GetTensorData<float>();int64_t steps=shape[1],classes=shape[2];std::string text;double confidence=0;int count=0,previous=-1;
        for(int64_t t=0;t<steps;t++) {
            const float* row=scores+t*classes;int current=(int)std::distance(row,std::max_element(row,row+classes));
            if(current!=0&&current!=previous){text+=characters[current];confidence+=row[current];count++;}previous=current;
        }
        Decode result{text,count?(float)(confidence/count):0};cache[key]=result;order.push_back(key);
        while(order.size()>768){cache.erase(order.front());order.pop_front();}return result;
    }
    NSDictionary* process(NSString* path) {
        auto start=std::chrono::steady_clock::now();auto image=readImage(path);int width=image.cols,height=image.rows;
        double scale=std::min(1.,1280./std::max(width,height));int dw=std::max(32,(int)std::round(width*scale/32)*32),dh=std::max(32,(int)std::round(height*scale/32)*32);
        auto input=tensor(image,dw,dh);auto output=run(det,detIn,detOut,input,dw,dh);
        auto shape=output.GetTensorTypeAndShapeInfo().GetShape();if(shape.size()!=4||shape[2]<=0||shape[3]<=0)throw std::runtime_error("Unexpected detection output");
        int mh=(int)shape[2],mw=(int)shape[3];cv::Mat map(mh,mw,CV_32F,const_cast<float*>(output.GetTensorData<float>()));
        cv::Mat bitmap;cv::threshold(map,bitmap,.3,255,cv::THRESH_BINARY);bitmap.convertTo(bitmap,CV_8U);
        cv::dilate(bitmap,bitmap,cv::getStructuringElement(cv::MORPH_RECT,cv::Size(2,2)));
        std::vector<std::vector<cv::Point>> contours;cv::findContours(bitmap,contours,cv::RETR_LIST,cv::CHAIN_APPROX_SIMPLE);
        struct Box{std::vector<cv::Point2f> points;cv::Rect bounds;};std::vector<Box> boxes;
        for(const auto& contour:contours) {
            if(boxes.size()>=1000||contour.size()<3)continue;auto rect=cv::minAreaRect(contour);
            if(std::min(rect.size.width,rect.size.height)<3)continue;
            auto roi=cv::boundingRect(contour)&cv::Rect(0,0,mw,mh);cv::Mat mask=cv::Mat::zeros(roi.size(),CV_8U);
            std::vector<cv::Point> translated;for(auto p:contour)translated.push_back(p-roi.tl());cv::fillPoly(mask,std::vector<std::vector<cv::Point>>{translated},cv::Scalar(255));
            if(cv::mean(map(roi),mask)[0]<.5)continue;
            float expand=(float)(std::abs(cv::contourArea(contour))*1.6/std::max(1.,cv::arcLength(contour,true)));
            rect.size.width+=2*expand;rect.size.height+=2*expand;cv::Point2f points[4];rect.points(points);
            std::vector<cv::Point2f> p(points,points+4);std::sort(p.begin(),p.end(),[](auto a,auto b){return a.x<b.x;});
            if(p[0].y>p[1].y)std::swap(p[0],p[1]);if(p[2].y>p[3].y)std::swap(p[2],p[3]);
            std::vector<cv::Point2f> ordered={p[0],p[2],p[3],p[1]};
            for(auto& point:ordered){point.x=std::clamp(point.x*width/mw,0.f,(float)(width-1));point.y=std::clamp(point.y*height/mh,0.f,(float)(height-1));}
            auto bounds=cv::boundingRect(ordered)&cv::Rect(0,0,width,height);if(bounds.width<3||bounds.height<3)continue;boxes.push_back({ordered,bounds});
        }
        std::sort(boxes.begin(),boxes.end(),[](const Box& a,const Box& b){return a.bounds.y==b.bounds.y?a.bounds.x<b.bounds.x:a.bounds.y<b.bounds.y;});
        for(size_t i=1;i<boxes.size();i++)for(size_t j=i;j>0;j--) {
            auto& a=boxes[j-1];auto& b=boxes[j];if(std::abs(a.bounds.y-b.bounds.y)<std::min(a.bounds.height,b.bounds.height)*.45 && a.bounds.x>b.bounds.x)std::swap(a,b);else break;
        }
        NSMutableArray* regions=[NSMutableArray array];int hits=0;
        for(const auto& box:boxes) {
            const auto& p=box.points;int cw=(int)std::max(cv::norm(p[0]-p[1]),cv::norm(p[2]-p[3])),ch=(int)std::max(cv::norm(p[0]-p[3]),cv::norm(p[1]-p[2]));
            if(cw<2||ch<2)continue;cw=std::min(16000,cw);ch=std::min(16000,ch);
            std::vector<cv::Point2f> dest={{0,0},{(float)cw,0},{(float)cw,(float)ch},{0,(float)ch}};cv::Mat crop;
            cv::warpPerspective(image,crop,cv::getPerspectiveTransform(p,dest),cv::Size(cw,ch),cv::INTER_CUBIC,cv::BORDER_REPLICATE);
            if(ch>cw*1.5)cv::rotate(crop,crop,cv::ROTATE_90_COUNTERCLOCKWISE);
            bool cached=false;auto decoded=recognize(crop,cached);if(cached)hits++;if(decoded.text.empty()||decoded.score<.5)continue;
            NSString* text=[[NSString alloc] initWithBytes:decoded.text.data() length:decoded.text.size() encoding:NSUTF8StringEncoding];if(!text)continue;
            [regions addObject:@{@"text":text,@"x":@(box.bounds.x/(double)width),@"y":@(box.bounds.y/(double)height),@"width":@(box.bounds.width/(double)width),@"height":@(box.bounds.height/(double)height),@"confidence":@(decoded.score)}];
        }
        double elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
        return @{@"regions":regions,@"cachedLines":@(hits),@"seconds":@(elapsed),@"backend":@"ppocr-v6-small"};
    }
};
int main(int argc,char** argv) {
    @autoreleasepool {
        try {
            if(argc!=2)return 2;Engine engine(argv[1]);std::string line;
            while(std::getline(std::cin,line)) { @autoreleasepool {
                NSDictionary* response;
                try {
                    NSData* data=[NSData dataWithBytes:line.data() length:line.size()];NSDictionary* request=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if(![request isKindOfClass:[NSDictionary class]]||![request[@"image"] isKindOfClass:[NSString class]])throw std::runtime_error("Invalid OCR request");
                    response=engine.process(request[@"image"]);
                } catch(const std::exception& e) {response=@{@"error":@"Local neural OCR failed; original screenshot retained."};}
                NSData* encoded=[NSJSONSerialization dataWithJSONObject:response options:0 error:nil];std::cout.write((const char*)encoded.bytes,encoded.length);std::cout<<std::endl;
            }}
        } catch(const std::exception& e) {std::cerr<<"Could not initialize local OCR models."<<std::endl;return 1;}
    }return 0;
}
