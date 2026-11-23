import Foundation

enum TextVerification {
    static func insertion(original:String, text:String, location:Int, length:Int) -> String? {
        let source=original as NSString
        guard location>=0,length>=0,location<=source.length,length<=source.length-location else {return nil}
        return source.replacingCharacters(in:NSRange(location:location,length:length),with:text)
    }
}
