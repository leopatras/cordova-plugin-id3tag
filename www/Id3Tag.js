var Id3Tag = {
  getInfo: function(fileURL, successCallback, errorCallback) {
    cordova.exec(
      successCallback,
      errorCallback,
      "Id3Tag",
      "getInfo",
      fileURL
    );
  }
};

module.exports = Id3Tag;
